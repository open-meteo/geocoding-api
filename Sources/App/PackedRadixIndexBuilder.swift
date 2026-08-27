import Foundation
import Vapor

private struct SearchNameCandidate {
    let indexID: UInt16
    let country: UInt16
    let admin1ID: UInt32
    let row: UInt32
    let ranking: Float
    let characterCount: UInt16
    let nameOffset: Int
    let nameLength: Int
}

private struct SearchPostingCandidate {
    let country: UInt16
    let admin1ID: UInt32
    let row: UInt32
    let ranking: Float
}

private struct OrdinalViewRecord {
    let indexID: UInt16
    let characterCount: UInt16
    let area: UInt32
    let nameOrdinal: UInt32
    let maximumRank: Float
}

private struct AreaViewBuild {
    let indexID: UInt16
    let area: UInt32
    let entryStart: UInt32
    let entryCount: UInt32
    let treeStart: UInt32
    let treeLeafBase: UInt32
}

private func compareLexicographically(
    _ lhs: borrowing Span<UInt8>,
    _ rhs: borrowing Span<UInt8>
) -> Int {
    let common = min(lhs.count, rhs.count)
    for index in 0..<common {
        if lhs[index] < rhs[index] {
            return -1
        }
        if lhs[index] > rhs[index] {
            return 1
        }
    }
    if lhs.count < rhs.count {
        return -1
    }
    if lhs.count > rhs.count {
        return 1
    }
    return 0
}

private final class CandidateRunCursor {
    let mapped: MappedFile
    let bytes: UnsafeRawBufferPointer
    private(set) var candidate: SearchNameCandidate?
    private var nextOffset = 0

    init(url: URL) throws {
        mapped = try MappedFile(url: url)
        bytes = try mapped.bytes(offset: 0, length: UInt64(mapped.count))
        try advance()
    }

    func withName<Result>(
        _ value: SearchNameCandidate,
        _ body: (borrowing Span<UInt8>) throws -> Result
    ) rethrows -> Result {
        let name = UnsafeRawBufferPointer(
            rebasing: bytes[value.nameOffset..<value.nameOffset + value.nameLength]
        )
        return try body(Span(_unsafeBytes: name))
    }

    func advance() throws {
        guard nextOffset < bytes.count else {
            candidate = nil
            return
        }
        guard nextOffset + 24 <= bytes.count else {
            throw DatabaseBuildIOError.read(
                path: mapped.path,
                message: "truncated sorted search candidate"
            )
        }
        let nameLength = Int(bytes.readUInt32(at: nextOffset + 20))
        let nameOffset = nextOffset + 24
        guard nameLength <= bytes.count - nameOffset else {
            throw DatabaseBuildIOError.read(
                path: mapped.path,
                message: "sorted candidate name exceeds run"
            )
        }
        candidate = SearchNameCandidate(
            indexID: bytes.readUInt16(at: nextOffset),
            country: bytes.readUInt16(at: nextOffset + 2),
            admin1ID: bytes.readUInt32(at: nextOffset + 4),
            row: bytes.readUInt32(at: nextOffset + 8),
            ranking: Float(bitPattern: bytes.readUInt32(at: nextOffset + 12)),
            characterCount: bytes.readUInt16(at: nextOffset + 16),
            nameOffset: nameOffset,
            nameLength: nameLength
        )
        nextOffset = nameOffset + nameLength
    }
}

private struct CandidateMergeHeap {
    var values = [Int]()
    let cursors: [CandidateRunCursor]

    mutating func insert(_ run: Int) {
        values.append(run)
        var index = values.count - 1
        while index > 0 {
            let parent = (index - 1) / 2
            guard precedes(run: values[index], run: values[parent]) else {
                break
            }
            values.swapAt(index, parent)
            index = parent
        }
    }

    mutating func removeMinimum() -> Int? {
        guard !values.isEmpty else {
            return nil
        }
        if values.count == 1 {
            return values.removeLast()
        }
        let result = values[0]
        values[0] = values.removeLast()
        var index = 0
        while true {
            let left = index * 2 + 1
            guard left < values.count else {
                break
            }
            let right = left + 1
            let child =
                right < values.count
                    && precedes(run: values[right], run: values[left])
                ? right : left
            guard precedes(run: values[child], run: values[index]) else {
                break
            }
            values.swapAt(index, child)
            index = child
        }
        return result
    }

    private func precedes(run lhsIndex: Int, run rhsIndex: Int) -> Bool {
        let lhs = cursors[lhsIndex].candidate!
        let rhs = cursors[rhsIndex].candidate!
        if lhs.indexID != rhs.indexID {
            return lhs.indexID < rhs.indexID
        }
        let order = cursors[lhsIndex].withName(lhs) { lhsName in
            cursors[rhsIndex].withName(rhs) { rhsName in
                compareLexicographically(lhsName, rhsName)
            }
        }
        if order != 0 {
            return order < 0
        }
        if lhs.ranking != rhs.ranking {
            return lhs.ranking > rhs.ranking
        }
        if lhs.row != rhs.row {
            return lhs.row < rhs.row
        }
        if lhs.country != rhs.country {
            return lhs.country < rhs.country
        }
        return lhs.admin1ID < rhs.admin1ID
    }
}

private struct SerializedRadixEdge {
    let label: [UInt8]
    let childNode: UInt32
    let subtreeFirst: UInt32
    let subtreeCount: UInt32
}

private struct PendingRadixNode {
    let incomingByte: UInt8?
    var terminalOrdinal: UInt32?
    var children = [SerializedRadixEdge]()
}

private final class PackedRadixWriter {
    let nodeWriter: BufferedBinaryWriter
    let edgeWriter: BufferedBinaryWriter
    let labelWriter: BufferedBinaryWriter
    private(set) var nodeCount: UInt32 = 0
    private(set) var edgeCount: UInt32 = 0

    private var stack = [PendingRadixNode]()
    private var previousName = [UInt8]()

    init(workspace: URL) throws {
        nodeWriter = try BufferedBinaryWriter(
            url: workspace.appendingPathComponent("search-nodes.section")
        )
        edgeWriter = try BufferedBinaryWriter(
            url: workspace.appendingPathComponent("search-edges.section")
        )
        labelWriter = try BufferedBinaryWriter(
            url: workspace.appendingPathComponent("search-edge-labels.section")
        )
    }

    func beginIndex() {
        precondition(stack.isEmpty)
        stack = [PendingRadixNode(incomingByte: nil)]
        previousName.removeAll(keepingCapacity: true)
    }

    func add(name: borrowing Span<UInt8>, ordinal: UInt32) throws {
        var common = 0
        let limit = min(previousName.count, name.count)
        while common < limit, previousName[common] == name[common] {
            common += 1
        }
        while stack.count - 1 > common {
            try finalizeTop()
        }
        if common < name.count {
            for index in common..<name.count {
                stack.append(PendingRadixNode(incomingByte: name[index]))
            }
        }
        guard stack.last?.terminalOrdinal == nil else {
            throw DatabaseFormatError.invalidSection(
                .searchNodes,
                "duplicate normalized name reached radix emitter"
            )
        }
        stack[stack.count - 1].terminalOrdinal = ordinal
        previousName = name.withUnsafeBufferPointer { Array($0) }
    }

    func finishIndex() throws -> UInt32 {
        while stack.count > 1 {
            try finalizeTop()
        }
        guard stack.count == 1 else {
            throw DatabaseFormatError.invalidSection(.searchNodes, "radix stack is empty")
        }
        let root = stack.removeLast()
        let serialized = try serialize(root)
        previousName.removeAll(keepingCapacity: true)
        return serialized.node
    }

    private func finalizeTop() throws {
        let node = stack.removeLast()
        guard let incoming = node.incomingByte else {
            throw DatabaseFormatError.invalidSection(.searchNodes, "invalid radix root")
        }
        let edge: SerializedRadixEdge
        if let terminal = node.terminalOrdinal, node.children.isEmpty {
            guard terminal < 0x8000_0000 else {
                throw GeoNamesImportError.tooManyValues("names in one search index")
            }
            edge = SerializedRadixEdge(
                label: [incoming],
                childNode: terminal | 0x8000_0000,
                subtreeFirst: terminal,
                subtreeCount: 1
            )
        } else if node.terminalOrdinal == nil, node.children.count == 1 {
            let child = node.children[0]
            var label = [incoming]
            label.append(contentsOf: child.label)
            edge = SerializedRadixEdge(
                label: label,
                childNode: child.childNode,
                subtreeFirst: child.subtreeFirst,
                subtreeCount: child.subtreeCount
            )
        } else {
            let serialized = try serialize(node)
            edge = SerializedRadixEdge(
                label: [incoming],
                childNode: serialized.node,
                subtreeFirst: serialized.first,
                subtreeCount: serialized.count
            )
        }
        stack[stack.count - 1].children.append(edge)
    }

    private func serialize(
        _ node: PendingRadixNode
    ) throws -> (node: UInt32, first: UInt32, count: UInt32) {
        let firstEdge = edgeCount
        var previousFirstByte: UInt8?
        for edge in node.children {
            guard let firstByte = edge.label.first else {
                throw DatabaseFormatError.invalidSection(.searchEdges, "empty radix edge")
            }
            if let previousFirstByte, firstByte <= previousFirstByte {
                throw DatabaseFormatError.invalidSection(
                    .searchEdges,
                    "radix edges are not strictly ordered"
                )
            }
            previousFirstByte = firstByte
            guard let labelLength = UInt16(exactly: edge.label.count) else {
                throw GeoNamesImportError.tooManyValues("bytes in a radix edge")
            }
            let labelOffset = try labelWriter.currentUInt32Offset()
            try edge.label.withUnsafeBytes { try labelWriter.write($0) }
            try edgeWriter.write(edge.childNode)
            try edgeWriter.write(labelOffset)
            try edgeWriter.write(labelLength)
            try edgeWriter.write(firstByte)
            try edgeWriter.write(UInt8(0))
            edgeCount += 1
        }
        guard let edgeCountCompact = UInt16(exactly: node.children.count) else {
            throw GeoNamesImportError.tooManyValues("radix edges on one node")
        }
        let first: UInt32
        var count: UInt32 = node.terminalOrdinal == nil ? 0 : 1
        if let terminal = node.terminalOrdinal {
            first = terminal
        } else if let child = node.children.first {
            first = child.subtreeFirst
        } else {
            throw DatabaseFormatError.invalidSection(.searchNodes, "empty radix node")
        }
        for child in node.children {
            count += child.subtreeCount
        }
        let nodeID = nodeCount
        try nodeWriter.write(firstEdge)
        try nodeWriter.write(edgeCountCompact)
        try nodeWriter.write(node.terminalOrdinal == nil ? UInt16(0) : UInt16(1))
        try nodeWriter.write(first)
        try nodeWriter.write(count)
        nodeCount += 1
        return (nodeID, first, count)
    }
}

private func writeRankBoundTree(
    leaves: [UInt16],
    writer: BufferedBinaryWriter,
    nodeCount: inout UInt32
) throws -> UInt32 {
    let bins = PackedRadixIndexLayout.rankBinCount
    let leafCount = max(1, leaves.count / bins)
    var leafBase = 1
    while leafBase < leafCount {
        leafBase *= 2
    }
    var nodes = [UInt16](
        repeating: PackedRadixIndexLayout.emptyRankBound,
        count: leafBase * 2 * bins
    )
    for leaf in 0..<(leaves.count / bins) {
        let destination = (leafBase + leaf) * bins
        for bin in 0..<bins {
            nodes[destination + bin] = leaves[leaf * bins + bin]
        }
    }
    if leafBase > 1 {
        for node in stride(from: leafBase - 1, through: 1, by: -1) {
            for bin in 0..<bins {
                let lhs = nodes[node * 2 * bins + bin]
                let rhs = nodes[(node * 2 + 1) * bins + bin]
                if lhs == PackedRadixIndexLayout.emptyRankBound {
                    nodes[node * bins + bin] = rhs
                } else if rhs == PackedRadixIndexLayout.emptyRankBound {
                    nodes[node * bins + bin] = lhs
                } else {
                    nodes[node * bins + bin] = max(lhs, rhs)
                }
            }
        }
    }
    for value in nodes {
        try writer.write(value)
    }
    nodeCount += UInt32(leafBase * 2)
    return UInt32(leafBase)
}

private final class SearchIndexSectionWriter {
    let rootWriter: BufferedBinaryWriter
    let metadataWriter: BufferedBinaryWriter
    let postingWriter: BufferedBinaryWriter
    let globalTreeWriter: BufferedBinaryWriter
    let radix: PackedRadixWriter
    let countryViewWriters: [BufferedBinaryWriter]
    let adminViewWriters: [BufferedBinaryWriter]

    private(set) var metadataCount: UInt32 = 0
    private(set) var postingCount: UInt32 = 0
    private var treeNodeCount: UInt32 = 0
    private var currentIndex: UInt16?
    private var currentNameBase: UInt32 = 0
    private var currentOrdinal: UInt32 = 0
    private var leafItemCount = 0
    private var leafSummary = LengthBinnedRankBounds()
    private var leafValues = [UInt16]()

    init(workspace: URL, viewPartitionCount: Int) throws {
        rootWriter = try BufferedBinaryWriter(
            url: workspace.appendingPathComponent("search-roots.section")
        )
        metadataWriter = try BufferedBinaryWriter(
            url: workspace.appendingPathComponent("search-name-metadata.section")
        )
        postingWriter = try BufferedBinaryWriter(
            url: workspace.appendingPathComponent("search-postings.section")
        )
        globalTreeWriter = try BufferedBinaryWriter(
            url: workspace.appendingPathComponent("search-global-trees.section")
        )
        radix = try PackedRadixWriter(workspace: workspace)
        var country = [BufferedBinaryWriter]()
        var admin = [BufferedBinaryWriter]()
        for partition in 0..<viewPartitionCount {
            country.append(
                try BufferedBinaryWriter(
                    url: workspace.appendingPathComponent("country-view-\(partition).part")
                )
            )
            admin.append(
                try BufferedBinaryWriter(
                    url: workspace.appendingPathComponent("admin-view-\(partition).part")
                )
            )
        }
        countryViewWriters = country
        adminViewWriters = admin
    }

    func emitGroup(
        indexID: UInt16,
        name: borrowing Span<UInt8>,
        characterCount: UInt16,
        candidates: [SearchPostingCandidate]
    ) throws {
        if currentIndex != indexID {
            try finishIndex()
            currentIndex = indexID
            currentNameBase = metadataCount
            currentOrdinal = 0
            leafValues.removeAll(keepingCapacity: true)
            leafItemCount = 0
            leafSummary = LengthBinnedRankBounds()
            radix.beginIndex()
        }

        let postingStart = postingCount
        var countries = [UInt16: Float]()
        var admins = [UInt32: Float]()
        var previousRow: UInt32?
        var acceptedCount: UInt32 = 0
        for candidate in candidates {
            if previousRow == candidate.row {
                continue
            }
            previousRow = candidate.row
            try postingWriter.write(candidate.row)
            try postingWriter.write(candidate.ranking)
            try postingWriter.write(candidate.country)
            try postingWriter.write(candidate.admin1ID)
            postingCount += 1
            acceptedCount += 1
            if candidate.country != 0 {
                countries[candidate.country] = max(
                    countries[candidate.country] ?? -.infinity,
                    candidate.ranking
                )
            }
            if candidate.admin1ID != 0 {
                admins[candidate.admin1ID] = max(
                    admins[candidate.admin1ID] ?? -.infinity,
                    candidate.ranking
                )
            }
        }
        try metadataWriter.write(postingStart)
        try metadataWriter.write(acceptedCount)
        try metadataWriter.write(characterCount)
        try metadataWriter.write(UInt16(0))
        metadataCount += 1

        try radix.add(name: name, ordinal: currentOrdinal)
        let maximumRank = candidates.first?.ranking ?? 0
        leafSummary.insert(rank: maximumRank, characterCount: characterCount)
        leafItemCount += 1
        if leafItemCount == PackedRadixIndexLayout.namesPerLeaf {
            leafSummary.append(to: &leafValues)
            leafSummary = LengthBinnedRankBounds()
            leafItemCount = 0
        }

        for (country, rank) in countries {
            try writeViewRecord(
                writer: countryViewWriters[viewPartition(indexID: indexID, area: UInt32(country))],
                indexID: indexID,
                characterCount: characterCount,
                area: UInt32(country),
                nameOrdinal: currentOrdinal,
                maximumRank: rank
            )
        }
        for (admin, rank) in admins {
            try writeViewRecord(
                writer: adminViewWriters[viewPartition(indexID: indexID, area: admin)],
                indexID: indexID,
                characterCount: characterCount,
                area: admin,
                nameOrdinal: currentOrdinal,
                maximumRank: rank
            )
        }
        currentOrdinal += 1
    }

    func finish() throws {
        try finishIndex()
        for writer in countryViewWriters + adminViewWriters {
            _ = try writer.close()
        }
    }

    private func finishIndex() throws {
        guard let indexID = currentIndex else {
            return
        }
        if leafItemCount > 0 {
            leafSummary.append(to: &leafValues)
        }
        let treeStart = treeNodeCount
        let leafBase = try writeRankBoundTree(
            leaves: leafValues,
            writer: globalTreeWriter,
            nodeCount: &treeNodeCount
        )
        let rootNode = try radix.finishIndex()
        try rootWriter.write(indexID)
        try rootWriter.write(UInt16(0))
        try rootWriter.write(rootNode)
        try rootWriter.write(currentNameBase)
        try rootWriter.write(currentOrdinal)
        try rootWriter.write(treeStart)
        try rootWriter.write(leafBase)
        currentIndex = nil
    }

    private func viewPartition(indexID: UInt16, area: UInt32) -> Int {
        var hash = UInt32(indexID) &* 2_654_435_761
        hash ^= area &* 2_246_822_519
        return Int(hash & UInt32(countryViewWriters.count - 1))
    }

    private func writeViewRecord(
        writer: BufferedBinaryWriter,
        indexID: UInt16,
        characterCount: UInt16,
        area: UInt32,
        nameOrdinal: UInt32,
        maximumRank: Float
    ) throws {
        try writer.write(indexID)
        try writer.write(characterCount)
        try writer.write(area)
        try writer.write(nameOrdinal)
        try writer.write(maximumRank)
    }
}

final class PackedRadixIndexBuilder {
    private let logger: Logger
    private let workspace: URL
    private let sourcePartitions: [URL]
    private let memoryLimitBytes: Int
    private let fileManager = FileManager.default

    init(
        logger: Logger,
        workspace: URL,
        sourcePartitions: [URL],
        memoryLimitBytes: Int
    ) {
        self.logger = logger
        self.workspace = workspace
        self.sourcePartitions = sourcePartitions
        self.memoryLimitBytes = memoryLimitBytes
    }

    func build() async throws -> [DatabaseSectionArtifact] {
        let runs = try await makeSortedRuns()
        defer {
            for url in runs {
                try? fileManager.removeItem(at: url)
            }
        }
        let output = try SearchIndexSectionWriter(
            workspace: workspace,
            viewPartitionCount: 32
        )
        try merge(runs: runs, output: output)
        try output.finish()

        var artifacts = [DatabaseSectionArtifact]()
        artifacts.append(
            try closeArtifact(
                kind: .searchRoots,
                writer: output.rootWriter,
                stride: UInt32(PackedRadixIndexLayout.rootStride)
            )
        )
        artifacts.append(
            try closeArtifact(
                kind: .searchNodes,
                writer: output.radix.nodeWriter,
                stride: UInt32(PackedRadixIndexLayout.nodeStride)
            )
        )
        artifacts.append(
            try closeArtifact(
                kind: .searchEdges,
                writer: output.radix.edgeWriter,
                stride: UInt32(PackedRadixIndexLayout.edgeStride)
            )
        )
        artifacts.append(
            try closeArtifact(
                kind: .searchEdgeLabels,
                writer: output.radix.labelWriter,
                stride: 1
            )
        )
        artifacts.append(
            try closeArtifact(
                kind: .searchNameMetadata,
                writer: output.metadataWriter,
                stride: UInt32(PackedRadixIndexLayout.nameMetadataStride)
            )
        )
        artifacts.append(
            try closeArtifact(
                kind: .searchPostings,
                writer: output.postingWriter,
                stride: UInt32(PackedRadixIndexLayout.postingStride)
            )
        )
        artifacts.append(
            try closeArtifact(
                kind: .searchGlobalTrees,
                writer: output.globalTreeWriter,
                stride: UInt32(PackedRadixIndexLayout.treeNodeStride)
            )
        )
        artifacts.append(
            contentsOf: try buildAreaView(
                kind: "country",
                partitions: output.countryViewWriters.map(\.url),
                bucketSection: .searchCountryBuckets,
                entrySection: .searchCountryEntries,
                treeSection: .searchCountryTrees
            )
        )
        artifacts.append(
            contentsOf: try buildAreaView(
                kind: "admin",
                partitions: output.adminViewWriters.map(\.url),
                bucketSection: .searchAdminBuckets,
                entrySection: .searchAdminEntries,
                treeSection: .searchAdminTrees
            )
        )
        return artifacts
    }

    private func makeSortedRuns() async throws -> [URL] {
        var jobs = [(partition: Int, url: URL, size: Int)]()
        for (partition, url) in sourcePartitions.enumerated() {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            if size == 0 {
                try fileManager.removeItem(at: url)
                continue
            }
            jobs.append((partition, url, size))
        }
        guard !jobs.isEmpty else {
            return []
        }

        let largestPartition = jobs.map(\.size).max() ?? 1
        let estimatedPartitionBytes =
            largestPartition > Int.max / 3
            ? Int.max : largestPartition * 3
        let estimatedBytesPerTask = max(32 << 20, estimatedPartitionBytes)
        let memoryBound = max(1, memoryLimitBytes / estimatedBytesPerTask)
        let concurrency = min(
            jobs.count,
            max(
                1,
                min(ProcessInfo.processInfo.activeProcessorCount, memoryBound)
            )
        )
        logger.info(
            "Packed radix index: sorting \(jobs.count) runs with automatic concurrency \(concurrency)"
        )
        let workspace = self.workspace

        return try await withThrowingTaskGroup(
            of: (Int, URL).self,
            returning: [URL].self
        ) { group in
            var nextJob = 0
            for _ in 0..<concurrency {
                let job = jobs[nextJob]
                group.addTask {
                    try Self.sortPartition(
                        partition: job.partition,
                        source: job.url,
                        workspace: workspace
                    )
                }
                nextJob += 1
            }

            var completed = [(Int, URL)]()
            completed.reserveCapacity(jobs.count)
            while let result = try await group.next() {
                completed.append(result)
                if nextJob < jobs.count {
                    let job = jobs[nextJob]
                    group.addTask {
                        try Self.sortPartition(
                            partition: job.partition,
                            source: job.url,
                            workspace: workspace
                        )
                    }
                    nextJob += 1
                }
            }
            return completed.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private static func sortPartition(
        partition: Int,
        source: URL,
        workspace: URL
    ) throws -> (Int, URL) {
        let mapped = try MappedFile(url: source)
        let bytes = try mapped.bytes(offset: 0, length: UInt64(mapped.count))
        var candidates = try parseCandidates(bytes: bytes, path: source.path)
        candidates.sort { compare($0, $1, bytes: bytes) }
        let runURL = workspace.appendingPathComponent(
            "search-sorted-\(partition).run"
        )
        let writer = try BufferedBinaryWriter(url: runURL)
        for candidate in candidates {
            try writer.write(candidate.indexID)
            try writer.write(candidate.country)
            try writer.write(candidate.admin1ID)
            try writer.write(candidate.row)
            try writer.write(candidate.ranking)
            try writer.write(candidate.characterCount)
            try writer.write(UInt16(0))
            try writer.write(UInt32(candidate.nameLength))
            try writer.write(
                Span(
                    _unsafeBytes: UnsafeRawBufferPointer(
                        rebasing: bytes[
                            candidate.nameOffset..<candidate.nameOffset + candidate.nameLength
                        ]
                    )
                )
            )
        }
        _ = try writer.close()
        try FileManager.default.removeItem(at: source)
        return (partition, runURL)
    }

    private func merge(
        runs: [URL],
        output: SearchIndexSectionWriter
    ) throws {
        let cursors = try runs.map(CandidateRunCursor.init)
        var heap = CandidateMergeHeap(cursors: cursors)
        for index in cursors.indices where cursors[index].candidate != nil {
            heap.insert(index)
        }
        var currentIndex: UInt16?
        var currentName = [UInt8]()
        var currentCharacters: UInt16 = 0
        var group = [SearchPostingCandidate]()

        func finishGroup() throws {
            guard let currentIndex else {
                return
            }
            try currentName.withUnsafeBufferPointer {
                try output.emitGroup(
                    indexID: currentIndex,
                    name: Span(_unsafeElements: $0),
                    characterCount: currentCharacters,
                    candidates: group
                )
            }
        }

        while let run = heap.removeMinimum() {
            let cursor = cursors[run]
            let candidate = cursor.candidate!
            try cursor.withName(candidate) { name in
                let sameGroup =
                    currentIndex == candidate.indexID
                    && currentName.count == name.count
                    && currentName.withUnsafeBufferPointer {
                        compareLexicographically(
                            Span(_unsafeElements: $0),
                            name
                        ) == 0
                    }
                if !sameGroup {
                    try finishGroup()
                    currentIndex = candidate.indexID
                    currentName = name.withUnsafeBufferPointer { Array($0) }
                    currentCharacters = candidate.characterCount
                    group.removeAll(keepingCapacity: true)
                }
            }
            group.append(
                SearchPostingCandidate(
                    country: candidate.country,
                    admin1ID: candidate.admin1ID,
                    row: candidate.row,
                    ranking: candidate.ranking
                )
            )
            try cursor.advance()
            if cursor.candidate != nil {
                heap.insert(run)
            }
        }
        try finishGroup()
    }

    private func buildAreaView(
        kind: String,
        partitions: [URL],
        bucketSection: DatabaseSectionKind,
        entrySection: DatabaseSectionKind,
        treeSection: DatabaseSectionKind
    ) throws -> [DatabaseSectionArtifact] {
        let entryWriter = try BufferedBinaryWriter(
            url: workspace.appendingPathComponent("search-\(kind)-entries.section")
        )
        let treeWriter = try BufferedBinaryWriter(
            url: workspace.appendingPathComponent("search-\(kind)-trees.section")
        )
        var entryCount: UInt32 = 0
        var treeNodeCount: UInt32 = 0
        var buckets = [AreaViewBuild]()

        for url in partitions {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            if (attributes[.size] as? NSNumber)?.uint64Value == 0 {
                try fileManager.removeItem(at: url)
                continue
            }
            let mapped = try MappedFile(url: url)
            let bytes = try mapped.bytes(offset: 0, length: UInt64(mapped.count))
            guard bytes.count % 16 == 0 else {
                throw DatabaseBuildIOError.read(
                    path: url.path,
                    message: "invalid area view record size"
                )
            }
            var records = [OrdinalViewRecord]()
            records.reserveCapacity(bytes.count / 16)
            for offset in stride(from: 0, to: bytes.count, by: 16) {
                records.append(
                    OrdinalViewRecord(
                        indexID: bytes.readUInt16(at: offset),
                        characterCount: bytes.readUInt16(at: offset + 2),
                        area: bytes.readUInt32(at: offset + 4),
                        nameOrdinal: bytes.readUInt32(at: offset + 8),
                        maximumRank: Float(
                            bitPattern: bytes.readUInt32(at: offset + 12)
                        )
                    )
                )
            }
            records.sort {
                if $0.indexID != $1.indexID {
                    return $0.indexID < $1.indexID
                }
                if $0.area != $1.area {
                    return $0.area < $1.area
                }
                return $0.nameOrdinal < $1.nameOrdinal
            }
            var offset = 0
            while offset < records.count {
                let indexID = records[offset].indexID
                let area = records[offset].area
                let entryStart = entryCount
                var leafCount = 0
                var leafSummary = LengthBinnedRankBounds()
                var leafValues = [UInt16]()
                while offset < records.count,
                    records[offset].indexID == indexID,
                    records[offset].area == area
                {
                    let record = records[offset]
                    try entryWriter.write(record.nameOrdinal)
                    try entryWriter.write(
                        PackedRadixIndexLayout.encodeRankBound(record.maximumRank)
                    )
                    entryCount += 1
                    leafSummary.insert(
                        rank: record.maximumRank,
                        characterCount: record.characterCount
                    )
                    leafCount += 1
                    if leafCount == PackedRadixIndexLayout.namesPerLeaf {
                        leafSummary.append(to: &leafValues)
                        leafSummary = LengthBinnedRankBounds()
                        leafCount = 0
                    }
                    offset += 1
                }
                if leafCount > 0 {
                    leafSummary.append(to: &leafValues)
                }
                let treeStart = treeNodeCount
                let leafBase = try writeRankBoundTree(
                    leaves: leafValues,
                    writer: treeWriter,
                    nodeCount: &treeNodeCount
                )
                buckets.append(
                    AreaViewBuild(
                        indexID: indexID,
                        area: area,
                        entryStart: entryStart,
                        entryCount: entryCount - entryStart,
                        treeStart: treeStart,
                        treeLeafBase: leafBase
                    )
                )
            }
            try fileManager.removeItem(at: url)
        }

        let bucketWriter = try BufferedBinaryWriter(
            url: workspace.appendingPathComponent("search-\(kind)-buckets.section")
        )
        for bucket in buckets.sorted(by: {
            $0.indexID != $1.indexID
                ? $0.indexID < $1.indexID : $0.area < $1.area
        }) {
            try bucketWriter.write(bucket.indexID)
            try bucketWriter.write(UInt16(0))
            try bucketWriter.write(bucket.area)
            try bucketWriter.write(bucket.entryStart)
            try bucketWriter.write(bucket.entryCount)
            try bucketWriter.write(bucket.treeStart)
            try bucketWriter.write(bucket.treeLeafBase)
            try bucketWriter.write(UInt32(0))
        }
        return [
            try closeArtifact(
                kind: bucketSection,
                writer: bucketWriter,
                stride: UInt32(PackedRadixIndexLayout.areaBucketStride)
            ),
            try closeArtifact(
                kind: entrySection,
                writer: entryWriter,
                stride: UInt32(PackedRadixIndexLayout.areaEntryStride)
            ),
            try closeArtifact(
                kind: treeSection,
                writer: treeWriter,
                stride: UInt32(PackedRadixIndexLayout.treeNodeStride)
            ),
        ]
    }

    private static func parseCandidates(
        bytes: UnsafeRawBufferPointer,
        path: String
    ) throws -> [SearchNameCandidate] {
        var result = [SearchNameCandidate]()
        result.reserveCapacity(max(1, bytes.count / 40))
        var offset = 0
        while offset < bytes.count {
            guard offset + 24 <= bytes.count else {
                throw DatabaseBuildIOError.read(path: path, message: "truncated search candidate")
            }
            let nameLength = Int(bytes.readUInt32(at: offset + 20))
            let nameOffset = offset + 24
            guard nameLength <= bytes.count - nameOffset else {
                throw DatabaseBuildIOError.read(
                    path: path,
                    message: "search candidate name exceeds partition"
                )
            }
            result.append(
                SearchNameCandidate(
                    indexID: bytes.readUInt16(at: offset),
                    country: bytes.readUInt16(at: offset + 2),
                    admin1ID: bytes.readUInt32(at: offset + 4),
                    row: bytes.readUInt32(at: offset + 8),
                    ranking: Float(bitPattern: bytes.readUInt32(at: offset + 12)),
                    characterCount: bytes.readUInt16(at: offset + 16),
                    nameOffset: nameOffset,
                    nameLength: nameLength
                )
            )
            offset = nameOffset + nameLength
        }
        return result
    }

    private static func compare(
        _ lhs: SearchNameCandidate,
        _ rhs: SearchNameCandidate,
        bytes: UnsafeRawBufferPointer
    ) -> Bool {
        if lhs.indexID != rhs.indexID {
            return lhs.indexID < rhs.indexID
        }
        let order = compareLexicographically(
            Span(
                _unsafeBytes: UnsafeRawBufferPointer(
                    rebasing: bytes[lhs.nameOffset..<lhs.nameOffset + lhs.nameLength]
                )
            ),
            Span(
                _unsafeBytes: UnsafeRawBufferPointer(
                    rebasing: bytes[rhs.nameOffset..<rhs.nameOffset + rhs.nameLength]
                )
            )
        )
        if order != 0 {
            return order < 0
        }
        if lhs.ranking != rhs.ranking {
            return lhs.ranking > rhs.ranking
        }
        if lhs.row != rhs.row {
            return lhs.row < rhs.row
        }
        if lhs.country != rhs.country {
            return lhs.country < rhs.country
        }
        return lhs.admin1ID < rhs.admin1ID
    }

    private func closeArtifact(
        kind: DatabaseSectionKind,
        writer: BufferedBinaryWriter,
        stride: UInt32
    ) throws -> DatabaseSectionArtifact {
        let result = try writer.close()
        guard result.length % UInt64(stride) == 0 else {
            throw DatabaseFormatError.invalidSection(kind, "builder emitted a partial record")
        }
        return DatabaseSectionArtifact(
            kind: kind,
            url: writer.url,
            length: result.length,
            count: result.length / UInt64(stride),
            stride: stride,
            hash: result.hash
        )
    }
}
