import Foundation
import Vapor

private struct SearchNameCandidate {
    let indexID: UInt16
    let country: UInt16
    let admin1ID: UInt32
    let row: UInt32
    let ranking: Float
    let characterCount: UInt16
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
        reader = try BinaryRecordReader(
            url: url,
            headerSize: SearchCandidateLayout.stride,
            lengthOffset: SearchCandidateLayout.byteCount
        )
        try advance()
    }

    func withName<Result>(
        _ body: (borrowing Span<UInt8>) throws -> Result
    ) rethrows -> Result {
        try record.withUnsafeBytes { bytes in
            try body(Span(_unsafeBytes: UnsafeRawBufferPointer(rebasing: bytes[SearchCandidateLayout.stride...])))
        }
    }

    func advance() throws {
        guard let record = try reader.next() else { candidate = nil; return }
        self.record = record
        candidate = record.withUnsafeBytes { bytes in
            SearchNameCandidate(
                indexID: bytes.readUInt16(at: SearchCandidateLayout.indexID),
                country: bytes.readUInt16(at: SearchCandidateLayout.country),
                admin1ID: bytes.readUInt32(at: SearchCandidateLayout.admin1ID),
                row: bytes.readUInt32(at: SearchCandidateLayout.row),
                ranking: Float(bitPattern: bytes.readUInt32(at: SearchCandidateLayout.rank)),
                characterCount: bytes.readUInt16(at: SearchCandidateLayout.characterCount)
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
            guard terminal < RadixEdgeLayout.leafFlag else {
                throw GeoNamesImportError.tooManyValues("names in one search index")
            }
            edge = SerializedRadixEdge(
                label: [incoming],
                childNode: terminal | RadixEdgeLayout.leafFlag,
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
            try edgeWriter.writeRecord(byteCount: RadixEdgeLayout.stride) { bytes in
                bytes.writeLittleEndian(edge.childNode, at: RadixEdgeLayout.child)
                bytes.writeLittleEndian(labelOffset, at: RadixEdgeLayout.labelOffset)
                bytes.writeLittleEndian(labelLength, at: RadixEdgeLayout.labelLength)
                bytes.writeLittleEndian(firstByte, at: RadixEdgeLayout.firstByte)
            }
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
        try nodeWriter.writeRecord(byteCount: RadixNodeLayout.stride) { bytes in
            bytes.writeLittleEndian(firstEdge, at: RadixNodeLayout.firstEdge)
            bytes.writeLittleEndian(edgeCountCompact, at: RadixNodeLayout.edgeCount)
            bytes.writeLittleEndian(
                node.terminalOrdinal == nil ? 0 : RadixNodeLayout.terminalFlag,
                at: RadixNodeLayout.flags
            )
            bytes.writeLittleEndian(first, at: RadixNodeLayout.subtreeFirst)
            bytes.writeLittleEndian(count, at: RadixNodeLayout.subtreeCount)
        }
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
        var seenRows = Set<UInt32>()
        var pending = try next()
        let maximumRank = pending?.ranking ?? 0
        while let candidate = pending {
            pending = try next()
            // Candidates are rank-sorted; aliases can give the same row different ranks.
            guard seenRows.insert(candidate.row).inserted else { continue }
            try postingWriter.writeRecord(byteCount: SearchPostingLayout.stride) { bytes in
                bytes.writeLittleEndian(candidate.row, at: SearchPostingLayout.row)
                bytes.writeLittleEndian(candidate.ranking.bitPattern, at: SearchPostingLayout.rank)
                bytes.writeLittleEndian(candidate.country, at: SearchPostingLayout.country)
                bytes.writeLittleEndian(candidate.admin1ID, at: SearchPostingLayout.admin1ID)
            }
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
        try metadataWriter.writeRecord(byteCount: NameMetadataLayout.stride) { bytes in
            bytes.writeLittleEndian(postingStart, at: NameMetadataLayout.postingStart)
            bytes.writeLittleEndian(acceptedCount, at: NameMetadataLayout.postingCount)
            bytes.writeLittleEndian(characterCount, at: NameMetadataLayout.characterCount)
        }
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
        try rootWriter.writeRecord(byteCount: RadixRootLayout.stride) { bytes in
            bytes.writeLittleEndian(indexID, at: RadixRootLayout.indexID)
            bytes.writeLittleEndian(rootNode, at: RadixRootLayout.rootNode)
            bytes.writeLittleEndian(currentNameBase, at: RadixRootLayout.nameBase)
            bytes.writeLittleEndian(currentOrdinal, at: RadixRootLayout.nameCount)
            bytes.writeLittleEndian(treeStart, at: RadixRootLayout.treeStart)
            bytes.writeLittleEndian(leafBase, at: RadixRootLayout.treeLeafBase)
        }
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
        try writer.writeRecord(byteCount: OrdinalViewLayout.stride) { bytes in
            bytes.writeLittleEndian(indexID, at: OrdinalViewLayout.indexID)
            bytes.writeLittleEndian(characterCount, at: OrdinalViewLayout.characterCount)
            bytes.writeLittleEndian(area, at: OrdinalViewLayout.area)
            bytes.writeLittleEndian(nameOrdinal, at: OrdinalViewLayout.nameOrdinal)
            bytes.writeLittleEndian(maximumRank.bitPattern, at: OrdinalViewLayout.maximumRank)
        }
    }
}

final class PackedRadixIndexBuilder {
    private let workspace: URL
    private let source: URL
    private let fileManager = FileManager.default

    init(
        workspace: URL,
        source: URL
    ) {
        self.workspace = workspace
        self.source = source
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
                stride: UInt32(RadixRootLayout.stride)
            )
        )
        artifacts.append(
            try closeArtifact(
                kind: .searchNodes,
                writer: output.radix.nodeWriter,
                stride: UInt32(RadixNodeLayout.stride)
            )
        )
        artifacts.append(
            try closeArtifact(
                kind: .searchEdges,
                writer: output.radix.edgeWriter,
                stride: UInt32(RadixEdgeLayout.stride)
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
                stride: UInt32(NameMetadataLayout.stride)
            )
        )
        artifacts.append(
            try closeArtifact(
                kind: .searchPostings,
                writer: output.postingWriter,
                stride: UInt32(SearchPostingLayout.stride)
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
                source: output.countryViewWriter.url,
                bucketSection: .searchCountryBuckets,
                entrySection: .searchCountryEntries,
                treeSection: .searchCountryTrees
            )
        )
        artifacts.append(
            contentsOf: try buildAreaView(
                kind: "admin",
                source: output.adminViewWriter.url,
                bucketSection: .searchAdminBuckets,
                entrySection: .searchAdminEntries,
                treeSection: .searchAdminTrees
            )
        )
        return artifacts
    }

    private func sortCandidates() throws -> URL {
        let run = try MappedRecordSort.sort(
            input: source,
            output: workspace.appendingPathComponent("search-sorted.tmp"),
            headerSize: SearchCandidateLayout.stride,
            lengthOffset: SearchCandidateLayout.byteCount
        ) { lhs, rhs in
            let leftID = lhs.readUInt16(at: SearchCandidateLayout.indexID)
            let rightID = rhs.readUInt16(at: SearchCandidateLayout.indexID)
            if leftID != rightID { return leftID < rightID }
            let order = compareLexicographically(
                Span(_unsafeBytes: UnsafeRawBufferPointer(rebasing: lhs[SearchCandidateLayout.stride...])),
                Span(_unsafeBytes: UnsafeRawBufferPointer(rebasing: rhs[SearchCandidateLayout.stride...]))
            )
            if order != 0 { return order < 0 }
            let leftRank = Float(bitPattern: lhs.readUInt32(at: SearchCandidateLayout.rank))
            let rightRank = Float(bitPattern: rhs.readUInt32(at: SearchCandidateLayout.rank))
            if leftRank != rightRank { return leftRank > rightRank }
            if lhs.readUInt32(at: SearchCandidateLayout.row) != rhs.readUInt32(at: SearchCandidateLayout.row) {
                return lhs.readUInt32(at: SearchCandidateLayout.row) < rhs.readUInt32(at: SearchCandidateLayout.row)
            }
            if lhs.readUInt16(at: SearchCandidateLayout.country) != rhs.readUInt16(at: SearchCandidateLayout.country) {
                return lhs.readUInt16(at: SearchCandidateLayout.country)
                    < rhs.readUInt16(at: SearchCandidateLayout.country)
            }
            return lhs.readUInt32(at: SearchCandidateLayout.admin1ID)
                < rhs.readUInt32(at: SearchCandidateLayout.admin1ID)
        }
        try fileManager.removeItem(at: source)
        return run
    }

    private func writeIndex(sortedCandidates: URL, output: SearchIndexSectionWriter) throws {
        let cursor = try CandidateRunCursor(url: sortedCandidates)
        while let first = cursor.candidate {
            let name = cursor.withName { $0.withUnsafeBufferPointer { Array($0) } }
            try name.withUnsafeBufferPointer { buffer in
                try output.emitGroup(
                    indexID: first.indexID,
                    name: Span(_unsafeElements: buffer),
                    characterCount: first.characterCount
                ) {
                    guard let candidate = cursor.candidate, candidate.indexID == first.indexID else { return nil }
                    let matches = cursor.withName {
                        compareLexicographically($0, Span(_unsafeElements: buffer)) == 0
                    }
                    guard matches else { return nil }
                    let result = SearchPostingCandidate(
                        country: candidate.country,
                        admin1ID: candidate.admin1ID,
                        row: candidate.row,
                        ranking: candidate.ranking
                    )
                    try cursor.advance()
                    return result
                }
            }
        }
    }

    private func buildAreaView(
        kind: String,
        source: URL,
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
        var buckets = [AreaOrdinalView]()

        let sorted = try MappedRecordSort.sort(
            input: source,
            output: workspace.appendingPathComponent("view-\(kind)-sorted.tmp"),
            headerSize: OrdinalViewLayout.stride
        ) { lhs, rhs in
            if lhs.readUInt16(at: OrdinalViewLayout.indexID) != rhs.readUInt16(at: OrdinalViewLayout.indexID) {
                return lhs.readUInt16(at: OrdinalViewLayout.indexID) < rhs.readUInt16(at: OrdinalViewLayout.indexID)
            }
            if lhs.readUInt32(at: OrdinalViewLayout.area) != rhs.readUInt32(at: OrdinalViewLayout.area) {
                return lhs.readUInt32(at: OrdinalViewLayout.area) < rhs.readUInt32(at: OrdinalViewLayout.area)
            }
            return lhs.readUInt32(at: OrdinalViewLayout.nameOrdinal) < rhs.readUInt32(at: OrdinalViewLayout.nameOrdinal)
        }
        try fileManager.removeItem(at: source)
        let reader = try BinaryRecordReader(url: sorted, headerSize: OrdinalViewLayout.stride)
        func next() throws -> OrdinalViewRecord? {
            try reader.withNextRecord { bytes in
                OrdinalViewRecord(
                    indexID: bytes.readUInt16(at: OrdinalViewLayout.indexID),
                    characterCount: bytes.readUInt16(at: OrdinalViewLayout.characterCount),
                    area: bytes.readUInt32(at: OrdinalViewLayout.area),
                    nameOrdinal: bytes.readUInt32(at: OrdinalViewLayout.nameOrdinal),
                    maximumRank: Float(bitPattern: bytes.readUInt32(at: OrdinalViewLayout.maximumRank))
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
                try entryWriter.writeRecord(byteCount: AreaEntryLayout.stride) { bytes in
                    bytes.writeLittleEndian(record.nameOrdinal, at: AreaEntryLayout.nameOrdinal)
                    bytes.writeLittleEndian(
                        PackedRadixIndexLayout.encodeRankBound(record.maximumRank),
                        at: AreaEntryLayout.rankBound
                    )
                }
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
                AreaOrdinalView(
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
            try bucketWriter.writeRecord(byteCount: AreaBucketLayout.stride) { bytes in
                bytes.writeLittleEndian(bucket.indexID, at: AreaBucketLayout.indexID)
                bytes.writeLittleEndian(bucket.area, at: AreaBucketLayout.area)
                bytes.writeLittleEndian(bucket.entryStart, at: AreaBucketLayout.entryStart)
                bytes.writeLittleEndian(bucket.entryCount, at: AreaBucketLayout.entryCount)
                bytes.writeLittleEndian(bucket.treeStart, at: AreaBucketLayout.treeStart)
                bytes.writeLittleEndian(bucket.treeLeafBase, at: AreaBucketLayout.treeLeafBase)
            }
        }
        return [
            try closeArtifact(
                kind: bucketSection,
                writer: bucketWriter,
                stride: UInt32(AreaBucketLayout.stride)
            ),
            try closeArtifact(
                kind: entrySection,
                writer: entryWriter,
                stride: UInt32(AreaEntryLayout.stride)
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
