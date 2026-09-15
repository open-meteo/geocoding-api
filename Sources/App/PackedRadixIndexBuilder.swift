import Foundation
import Vapor

private struct SearchNameCandidate {
    let indexID: UInt16
    let country: UInt16
    let admin1ID: UInt32
    let row: UInt32
    let ranking: Float
    var sources: MatchSources
    let characterCount: UInt16
    let nameOffset: Int
    let nameLength: Int
}

private struct SearchPostingCandidate {
    let country: UInt16
    let admin1ID: UInt32
    let row: UInt32
    let ranking: Float
    var sources: MatchSources
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
    private let reader: BinaryRecordReader
    private var record = Data()
    private(set) var candidate: SearchNameCandidate?

    init(url: URL) throws {
        reader = try BinaryRecordReader(url: url, headerSize: 24, lengthOffset: 20)
        try advance()
    }

    func withName<Result>(
        _ value: SearchNameCandidate,
        _ body: (borrowing Span<UInt8>) throws -> Result
    ) rethrows -> Result {
        try record.withUnsafeBytes { bytes in
            try body(Span(_unsafeBytes: UnsafeRawBufferPointer(rebasing: bytes[24...])))
        }
    }

    func advance() throws {
        guard let record = try reader.next() else { candidate = nil; return }
        self.record = record
        candidate = record.withUnsafeBytes { bytes in
            SearchNameCandidate(
                indexID: bytes.readUInt16(at: 0),
                country: bytes.readUInt16(at: 2),
                admin1ID: bytes.readUInt32(at: 4),
                row: bytes.readUInt32(at: 8),
                ranking: Float(bitPattern: bytes.readUInt32(at: 12)),
                sources: MatchSources(rawValue: bytes.readUInt16(at: 18)),
                characterCount: bytes.readUInt16(at: 16),
                nameOffset: 24,
                nameLength: record.count - 24
            )
        }
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
    let countryViewWriter: BufferedBinaryWriter
    let adminViewWriter: BufferedBinaryWriter

    private(set) var metadataCount: UInt32 = 0
    private(set) var postingCount: UInt32 = 0
    private var treeNodeCount: UInt32 = 0
    private var currentIndex: UInt16?
    private var currentNameBase: UInt32 = 0
    private var currentOrdinal: UInt32 = 0
    private var leafItemCount = 0
    private var leafSummary = LengthBinnedRankBounds()
    private var leafValues = [UInt16]()

    init(workspace: URL) throws {
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
        countryViewWriter = try BufferedBinaryWriter(url: workspace.appendingPathComponent("country-view.input"))
        adminViewWriter = try BufferedBinaryWriter(url: workspace.appendingPathComponent("admin-view.input"))
    }

    func emitGroup(
        indexID: UInt16,
        name: borrowing Span<UInt8>,
        characterCount: UInt16,
        next: () throws -> SearchPostingCandidate?
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
        var acceptedCount: UInt32 = 0
        var pending = try next()
        let maximumRank = pending?.ranking ?? 0
        while var candidate = pending {
            pending = try next()
            while let duplicate = pending, duplicate.row == candidate.row {
                candidate.sources.formUnion(duplicate.sources)
                pending = try next()
            }
            try postingWriter.write(candidate.row)
            try postingWriter.write(candidate.ranking)
            try postingWriter.write(candidate.country)
            try postingWriter.write(candidate.admin1ID)
            try postingWriter.write(candidate.sources.rawValue)
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
        leafSummary.insert(rank: maximumRank, characterCount: characterCount)
        leafItemCount += 1
        if leafItemCount == PackedRadixIndexLayout.namesPerLeaf {
            leafSummary.append(to: &leafValues)
            leafSummary = LengthBinnedRankBounds()
            leafItemCount = 0
        }

        for (country, rank) in countries {
            try writeViewRecord(
                writer: countryViewWriter,
                indexID: indexID,
                characterCount: characterCount,
                area: UInt32(country),
                nameOrdinal: currentOrdinal,
                maximumRank: rank
            )
        }
        for (admin, rank) in admins {
            try writeViewRecord(
                writer: adminViewWriter,
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
        for writer in [countryViewWriter, adminViewWriter] {
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
    private let source: URL
    private let memoryLimitBytes: Int
    private let fileManager = FileManager.default

    init(
        logger: Logger,
        workspace: URL,
        source: URL,
        memoryLimitBytes: Int
    ) {
        self.logger = logger
        self.workspace = workspace
        self.source = source
        self.memoryLimitBytes = memoryLimitBytes
    }

    func build() throws -> [DatabaseSectionArtifact] {
        let sortedCandidates = try sortCandidates()
        defer { try? fileManager.removeItem(at: sortedCandidates) }
        let output = try SearchIndexSectionWriter(
            workspace: workspace
        )
        try writeIndex(sortedCandidates: sortedCandidates, output: output)
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
                partitions: [output.countryViewWriter.url],
                bucketSection: .searchCountryBuckets,
                entrySection: .searchCountryEntries,
                treeSection: .searchCountryTrees
            )
        )
        artifacts.append(
            contentsOf: try buildAreaView(
                kind: "admin",
                partitions: [output.adminViewWriter.url],
                bucketSection: .searchAdminBuckets,
                entrySection: .searchAdminEntries,
                treeSection: .searchAdminTrees
            )
        )
        return artifacts
    }

    private func sortCandidates() throws -> URL {
        let run = try ExternalSort.sort(
            inputs: [source],
            workspace: workspace,
            label: "search",
            headerSize: 24,
            lengthOffset: 20,
            memoryBytes: memoryLimitBytes
        ) { lhs, rhs in
            let leftID = lhs.readUInt16(at: 0)
            let rightID = rhs.readUInt16(at: 0)
            if leftID != rightID { return leftID < rightID }
            let order = compareLexicographically(
                Span(_unsafeBytes: UnsafeRawBufferPointer(rebasing: lhs[24...])),
                Span(_unsafeBytes: UnsafeRawBufferPointer(rebasing: rhs[24...]))
            )
            if order != 0 { return order < 0 }
            let leftRank = Float(bitPattern: lhs.readUInt32(at: 12))
            let rightRank = Float(bitPattern: rhs.readUInt32(at: 12))
            if leftRank != rightRank { return leftRank > rightRank }
            if lhs.readUInt32(at: 8) != rhs.readUInt32(at: 8) { return lhs.readUInt32(at: 8) < rhs.readUInt32(at: 8) }
            if lhs.readUInt16(at: 2) != rhs.readUInt16(at: 2) { return lhs.readUInt16(at: 2) < rhs.readUInt16(at: 2) }
            return lhs.readUInt32(at: 4) < rhs.readUInt32(at: 4)
        }
        try fileManager.removeItem(at: source)
        return run
    }

    private func writeIndex(sortedCandidates: URL, output: SearchIndexSectionWriter) throws {
        let cursor = try CandidateRunCursor(url: sortedCandidates)
        while let first = cursor.candidate {
            let name = cursor.withName(first) { $0.withUnsafeBufferPointer { Array($0) } }
            try name.withUnsafeBufferPointer { buffer in
                try output.emitGroup(
                    indexID: first.indexID,
                    name: Span(_unsafeElements: buffer),
                    characterCount: first.characterCount
                ) {
                    guard let candidate = cursor.candidate, candidate.indexID == first.indexID else { return nil }
                    let matches = cursor.withName(candidate) {
                        compareLexicographically($0, Span(_unsafeElements: buffer)) == 0
                    }
                    guard matches else { return nil }
                    let result = SearchPostingCandidate(
                        country: candidate.country,
                        admin1ID: candidate.admin1ID,
                        row: candidate.row,
                        ranking: candidate.ranking,
                        sources: candidate.sources
                    )
                    try cursor.advance()
                    return result
                }
            }
        }
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

        let sorted = try ExternalSort.sort(
            inputs: partitions,
            workspace: workspace,
            label: "view-\(kind)",
            headerSize: 16,
            memoryBytes: memoryLimitBytes
        ) { lhs, rhs in
            if lhs.readUInt16(at: 0) != rhs.readUInt16(at: 0) { return lhs.readUInt16(at: 0) < rhs.readUInt16(at: 0) }
            if lhs.readUInt32(at: 4) != rhs.readUInt32(at: 4) { return lhs.readUInt32(at: 4) < rhs.readUInt32(at: 4) }
            return lhs.readUInt32(at: 8) < rhs.readUInt32(at: 8)
        }
        for url in partitions { try fileManager.removeItem(at: url) }
        let reader = try BinaryRecordReader(url: sorted, headerSize: 16)
        func next() throws -> OrdinalViewRecord? {
            try reader.withNextRecord { bytes in
                OrdinalViewRecord(
                    indexID: bytes.readUInt16(at: 0),
                    characterCount: bytes.readUInt16(at: 2),
                    area: bytes.readUInt32(at: 4),
                    nameOrdinal: bytes.readUInt32(at: 8),
                    maximumRank: Float(bitPattern: bytes.readUInt32(at: 12))
                )
            }
        }
        var current = try next()
        while let first = current {
            let indexID = first.indexID
            let area = first.area
            let entryStart = entryCount
            var leafCount = 0
            var leafSummary = LengthBinnedRankBounds()
            var leafValues = [UInt16]()
            while let record = current, record.indexID == indexID, record.area == area {
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
                current = try next()
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
        try fileManager.removeItem(at: sorted)

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
