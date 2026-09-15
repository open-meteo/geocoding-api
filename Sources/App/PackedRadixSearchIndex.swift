import Foundation

private struct RadixPrefixMatch {
    let range: Range<UInt32>
    let terminal: UInt32?
}

private enum SearchFilterScope: UInt8 {
    case global
    case country
    case admin
}

private struct SearchTraversalPath {
    let scope: SearchFilterScope
    let root: RadixIndexRoot
    let area: UInt32
    let itemStart: UInt32
    let itemCount: UInt32
    let treeStart: UInt32
    let treeLeafBase: UInt32
    let terminal: UInt32?
    let countryFilter: UInt16?
}

private struct SearchFrontierItem {
    let upperBound: Float
    let pathIndex: Int
    let node: UInt32
}

private struct SearchFrontierHeap {
    private var values = [SearchFrontierItem]()

    let diagnostics: SearchDiagnostics?

    init(diagnostics: SearchDiagnostics?) {
        self.diagnostics = diagnostics
    }

    mutating func insert(_ value: SearchFrontierItem) {
        if values.isEmpty { values.reserveCapacity(32) }
        values.append(value)
        var index = values.count - 1
        while index > 0 {
            let parent = (index - 1) / 2
            guard values[parent].upperBound < values[index].upperBound else {
                break
            }
            values.swapAt(parent, index)
            index = parent
        }
    }

    mutating func removeMaximum() -> SearchFrontierItem? {
        if !values.isEmpty { diagnostics?.treeNodesVisited += 1 }
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
                    && values[right].upperBound > values[left].upperBound
                ? right : left
            guard values[index].upperBound < values[child].upperBound else {
                break
            }
            values.swapAt(index, child)
            index = child
        }
        return result
    }
}

private struct SearchPathKeySet {
    private var inline = InlineArray<16, UInt64>(repeating: 0)
    private var count = 0
    private var overflow: Set<UInt64>?

    mutating func insert(_ key: UInt64) -> Bool {
        for index in 0..<count where inline[index] == key {
            return false
        }
        if count < inline.count {
            inline[count] = key
            count += 1
            return true
        }
        if overflow == nil {
            var values = Set<UInt64>(minimumCapacity: count * 2)
            for index in 0..<count {
                values.insert(inline[index])
            }
            overflow = values
        }
        return overflow!.insert(key).inserted
    }
}

private typealias RankedSearchResult = SearchHit

private struct TopKResultHeap {
    let capacity: Int
    private var heap = [RankedSearchResult]()

    let diagnostics: SearchDiagnostics?

    init(capacity: Int, diagnostics: SearchDiagnostics?) {
        self.diagnostics = diagnostics
        self.capacity = capacity
    }

    var isFull: Bool {
        return heap.count >= capacity
    }

    var worst: RankedSearchResult? {
        return heap.first
    }

    mutating func insert(row: UInt32, id: Int32, score: Float, sources: MatchSources) {
        // The API caps K at 100; scanning avoids hash updates on every heap swap.
        let existingIndex = heap.firstIndex(where: { $0.row == row })
        if let index = existingIndex {
            diagnostics?.duplicateHits += 1
            if score == heap[index].score { heap[index].sources.formUnion(sources) }
            guard score > heap[index].score else {
                return
            }
            diagnostics?.heapUpdates += 1
            heap[index].score = score
            heap[index].sources = sources
            siftDown(from: index)
            return
        }
        let value = RankedSearchResult(row: row, id: id, score: score, sources: sources)
        if heap.count < capacity {
            diagnostics?.heapInsertions += 1
            if heap.isEmpty { heap.reserveCapacity(capacity) }
            heap.append(value)
            siftUp(from: heap.count - 1)
            return
        }
        guard let worst, isBetter(value, than: worst) else {
            return
        }
        diagnostics?.heapReplacements += 1
        heap[0] = value
        siftDown(from: 0)
    }

    func sorted() -> [SearchHit] {
        heap.sorted {
            $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score
        }
    }

    private func isWorse(_ lhs: RankedSearchResult, than rhs: RankedSearchResult) -> Bool {
        if lhs.score != rhs.score {
            return lhs.score < rhs.score
        }
        return lhs.id > rhs.id
    }

    private func isBetter(_ lhs: RankedSearchResult, than rhs: RankedSearchResult) -> Bool {
        return isWorse(rhs, than: lhs)
    }

    private mutating func swap(_ lhs: Int, _ rhs: Int) {
        heap.swapAt(lhs, rhs)
    }

    private mutating func siftUp(from start: Int) {
        var index = start
        while index > 0 {
            let parent = (index - 1) / 2
            guard isWorse(heap[index], than: heap[parent]) else {
                break
            }
            swap(index, parent)
            index = parent
        }
    }

    private mutating func siftDown(from start: Int) {
        var index = start
        while true {
            let left = index * 2 + 1
            guard left < heap.count else {
                break
            }
            let right = left + 1
            let child =
                right < heap.count && isWorse(heap[right], than: heap[left])
                ? right : left
            guard isWorse(heap[child], than: heap[index]) else {
                break
            }
            swap(index, child)
            index = child
        }
    }
}

final class PackedRadixSearchIndex {
    private let mappedFile: MappedFile
    private let rowIDs: UnsafeRawBufferPointer
    private let recordCount: Int
    private let nodes: UnsafeRawBufferPointer
    private let edges: UnsafeRawBufferPointer
    private let labels: UnsafeRawBufferPointer
    private let metadata: UnsafeRawBufferPointer
    private let postings: UnsafeRawBufferPointer
    private let globalTrees: UnsafeRawBufferPointer
    private let countryBuckets: UnsafeRawBufferPointer
    private let countryEntries: UnsafeRawBufferPointer
    private let countryTrees: UnsafeRawBufferPointer
    private let adminBuckets: UnsafeRawBufferPointer
    private let adminEntries: UnsafeRawBufferPointer
    private let adminTrees: UnsafeRawBufferPointer
    private let roots: [RadixIndexRoot?]
    private let countryBucketCount: Int
    private let adminBucketCount: Int

    init(
        mappedFile: MappedFile,
        header: DatabaseFileHeader,
        sections: [DatabaseSectionKind: UnsafeRawBufferPointer]
    ) throws {
        self.mappedFile = mappedFile
        rowIDs = sections[.locations]!
        recordCount = Int(header.recordCount)
        nodes = sections[.searchNodes]!
        edges = sections[.searchEdges]!
        labels = sections[.searchEdgeLabels]!
        metadata = sections[.searchNameMetadata]!
        postings = sections[.searchPostings]!
        globalTrees = sections[.searchGlobalTrees]!
        countryBuckets = sections[.searchCountryBuckets]!
        countryEntries = sections[.searchCountryEntries]!
        countryTrees = sections[.searchCountryTrees]!
        adminBuckets = sections[.searchAdminBuckets]!
        adminEntries = sections[.searchAdminEntries]!
        adminTrees = sections[.searchAdminTrees]!
        countryBucketCount = Int(header.sections[.searchCountryBuckets]!.count)
        adminBucketCount = Int(header.sections[.searchAdminBuckets]!.count)

        let bytes = sections[.searchRoots]!
        let count = Int(header.sections[.searchRoots]!.count)
        var decodedRoots = [RadixIndexRoot]()
        decodedRoots.reserveCapacity(count)
        for index in 0..<count {
            let offset = index * PackedRadixIndexLayout.rootStride
            let root = RadixIndexRoot(
                indexID: bytes.readUInt16(at: offset),
                rootNode: bytes.readUInt32(at: offset + 4),
                nameBase: bytes.readUInt32(at: offset + 8),
                nameCount: bytes.readUInt32(at: offset + 12),
                treeStart: bytes.readUInt32(at: offset + 16),
                treeLeafBase: bytes.readUInt32(at: offset + 20)
            )
            let base = Int(root.nameBase)
            let names = Int(root.nameCount)
            let leaves = Int(root.treeLeafBase)
            guard root.nameCount <= 0x7fff_ffff,
                base <= metadata.count / PackedRadixIndexLayout.nameMetadataStride,
                names <= metadata.count / PackedRadixIndexLayout.nameMetadataStride - base,
                Int(root.rootNode) < nodes.count / PackedRadixIndexLayout.nodeStride,
                leaves > 0, leaves & (leaves - 1) == 0,
                leaves >= (names + 63) / 64,
                globalTrees.containsRange(offset: Int(root.treeStart) * 24, length: leaves * 2 * 24)
            else { throw DatabaseFormatError.invalidSection(.searchRoots, "invalid root ranges") }
            decodedRoots.append(root)
        }
        let maximumIndexID = decodedRoots.map(\.indexID).max() ?? 0
        var roots = [RadixIndexRoot?](
            repeating: nil,
            count: Int(maximumIndexID) + 1
        )
        for root in decodedRoots {
            roots[Int(root.indexID)] = root
        }
        self.roots = roots
    }

    func search(
        _ value: String,
        languageID: UInt16,
        count: Int,
        countryCode: String?,
        administrativeArea: AdministrativeAreaResolver.Resolution?,
        diagnostics: SearchDiagnostics? = nil
    ) throws -> [SearchHit] {
        defer { withExtendedLifetime(mappedFile) {} }
        guard count > 0 else { return [] }
        let prepared = NormalizedSearchQuery(value)
        let normalized = prepared.text
        guard !normalized.isEmpty else {
            return []
        }
        let queryCharacters = prepared.characterCount
        let onlyExact = prepared.onlyExact
        if let result = try normalized.utf8.withContiguousStorageIfAvailable({
            try search(
                query: Span(_unsafeElements: $0),
                queryCharacters: queryCharacters,
                onlyExact: onlyExact,
                languageID: languageID,
                count: count,
                countryCode: countryCode,
                administrativeArea: administrativeArea,
                diagnostics: diagnostics
            )
        }) {
            return result
        }
        let copiedQuery = Array(normalized.utf8)
        return try copiedQuery.withUnsafeBufferPointer {
            try search(
                query: Span(_unsafeElements: $0),
                queryCharacters: queryCharacters,
                onlyExact: onlyExact,
                languageID: languageID,
                count: count,
                countryCode: countryCode,
                administrativeArea: administrativeArea,
                diagnostics: diagnostics
            )
        }
    }

    private func search(
        query: borrowing Span<UInt8>,
        queryCharacters: Int,
        onlyExact: Bool,
        languageID: UInt16,
        count: Int,
        countryCode: String?,
        administrativeArea: AdministrativeAreaResolver.Resolution?,
        diagnostics: SearchDiagnostics? = nil
    ) throws -> [SearchHit] {
        let explicitCountry = countryCode.flatMap(GeocodingDatabase.countryValue)
        if countryCode != nil, explicitCountry == nil {
            return []
        }
        if let administrativeArea, administrativeArea.isEmpty {
            return []
        }

        var indexIDs = InlineArray<2, UInt16>(repeating: 0)
        let indexCount: Int
        if languageID == UInt16.max {
            indexCount = 1
        } else {
            indexIDs[1] = languageID + 1
            indexCount = 2
        }
        var frontier = SearchFrontierHeap(diagnostics: diagnostics)
        var results = TopKResultHeap(capacity: count, diagnostics: diagnostics)
        var pathKeys = SearchPathKeySet()
        var paths = [SearchTraversalPath]()

        for indexOffset in 0..<indexCount {
            let indexID = indexIDs[indexOffset]
            guard
                Int(indexID) < roots.count,
                let root = roots[Int(indexID)],
                let match = try prefixMatch(root: root, query: query)
            else {
                continue
            }
            if onlyExact, match.terminal == nil {
                continue
            }

            if let administrativeArea {
                for code in administrativeArea.countryCodes {
                    guard let country = GeocodingDatabase.countryValue(code) else {
                        continue
                    }
                    if let explicitCountry, country != explicitCountry {
                        continue
                    }
                    try addAreaPath(
                        scope: .country,
                        area: UInt32(country),
                        root: root,
                        match: match,
                        onlyExact: onlyExact,
                        queryCharacters: queryCharacters,
                        countryFilter: explicitCountry,
                        keySet: &pathKeys,
                        paths: &paths,
                        frontier: &frontier,
                        results: &results
                    )
                }
                for id in administrativeArea.admin1IDs where id > 0 {
                    try addAreaPath(
                        scope: .admin,
                        area: UInt32(bitPattern: id),
                        root: root,
                        match: match,
                        onlyExact: onlyExact,
                        queryCharacters: queryCharacters,
                        countryFilter: explicitCountry,
                        keySet: &pathKeys,
                        paths: &paths,
                        frontier: &frontier,
                        results: &results
                    )
                }
            } else if let explicitCountry {
                try addAreaPath(
                    scope: .country,
                    area: UInt32(explicitCountry),
                    root: root,
                    match: match,
                    onlyExact: onlyExact,
                    queryCharacters: queryCharacters,
                    countryFilter: explicitCountry,
                    keySet: &pathKeys,
                    paths: &paths,
                    frontier: &frontier,
                    results: &results
                )
            } else {
                let range =
                    onlyExact
                    ? match.terminal!..<match.terminal! + 1
                    : match.range
                let path = SearchTraversalPath(
                    scope: .global,
                    root: root,
                    area: 0,
                    itemStart: 0,
                    itemCount: root.nameCount,
                    treeStart: root.treeStart,
                    treeLeafBase: root.treeLeafBase,
                    terminal: match.terminal,
                    countryFilter: nil
                )
                let pathIndex = paths.count
                if paths.isEmpty { paths.reserveCapacity(8) }
                paths.append(path)
                try addRange(
                    path: path,
                    pathIndex: pathIndex,
                    range: range,
                    queryCharacters: queryCharacters,
                    onlyExact: onlyExact,
                    frontier: &frontier,
                    results: &results
                )
            }
        }

        while let item = frontier.removeMaximum() {
            if results.isFull, let worst = results.worst,
                item.upperBound < worst.score
            {
                break
            }
            let path = paths[item.pathIndex]
            if item.node < path.treeLeafBase {
                try addTreeNode(
                    path: path,
                    pathIndex: item.pathIndex,
                    node: item.node * 2,
                    queryCharacters: queryCharacters,
                    onlyExact: onlyExact,
                    frontier: &frontier
                )
                try addTreeNode(
                    path: path,
                    pathIndex: item.pathIndex,
                    node: item.node * 2 + 1,
                    queryCharacters: queryCharacters,
                    onlyExact: onlyExact,
                    frontier: &frontier
                )
            } else {
                let block = item.node - path.treeLeafBase
                let lower = block * UInt32(PackedRadixIndexLayout.namesPerLeaf)
                let upper = min(
                    path.itemCount,
                    lower + UInt32(PackedRadixIndexLayout.namesPerLeaf)
                )
                try scanItems(
                    path: path,
                    range: lower..<upper,
                    queryCharacters: queryCharacters,
                    results: &results
                )
            }
        }
        return results.sorted()
    }

    private func prefixMatch(
        root: RadixIndexRoot,
        query: borrowing Span<UInt8>
    ) throws -> RadixPrefixMatch? {
        var node = root.rootNode
        var queryOffset = 0
        while true {
            let nodeOffset = Int(node) * PackedRadixIndexLayout.nodeStride
            guard nodes.containsRange(offset: nodeOffset, length: PackedRadixIndexLayout.nodeStride) else {
                throw DatabaseFormatError.invalidSection(.searchNodes, "invalid query node")
            }
            if queryOffset == query.count {
                let first = nodes.readUInt32(at: nodeOffset + 8)
                let count = nodes.readUInt32(at: nodeOffset + 12)
                guard first < root.nameCount, count <= root.nameCount - first else {
                    throw DatabaseFormatError.invalidSection(.searchNodes, "invalid query ordinal range")
                }
                let terminal =
                    nodes.readUInt16(at: nodeOffset + 6) & 1 == 1
                    ? first : nil
                return RadixPrefixMatch(
                    range: first..<first + count,
                    terminal: terminal
                )
            }
            let firstEdge = Int(nodes.readUInt32(at: nodeOffset))
            let edgeCount = Int(nodes.readUInt16(at: nodeOffset + 4))
            guard
                let edge = try findEdge(
                    first: firstEdge,
                    count: edgeCount,
                    firstByte: query[queryOffset]
                )
            else {
                return nil
            }
            let edgeOffset = edge * PackedRadixIndexLayout.edgeStride
            let child = edges.readUInt32(at: edgeOffset)
            let isLeaf = child & 0x8000_0000 != 0
            let leafOrdinal = child & 0x7fff_ffff
            let labelOffset = Int(edges.readUInt32(at: edgeOffset + 4))
            let labelLength = Int(edges.readUInt16(at: edgeOffset + 8))
            guard labelLength > 0, labels.containsRange(offset: labelOffset, length: labelLength),
                !isLeaf || leafOrdinal < root.nameCount
            else {
                throw DatabaseFormatError.invalidSection(.searchEdges, "invalid query edge")
            }
            var labelIndex = 0
            while labelIndex < labelLength, queryOffset < query.count {
                guard labels[labelOffset + labelIndex] == query[queryOffset] else {
                    return nil
                }
                labelIndex += 1
                queryOffset += 1
            }
            if queryOffset == query.count, labelIndex < labelLength {
                if isLeaf {
                    return RadixPrefixMatch(
                        range: leafOrdinal..<leafOrdinal + 1,
                        terminal: nil
                    )
                }
                let childOffset = Int(child) * PackedRadixIndexLayout.nodeStride
                guard nodes.containsRange(offset: childOffset, length: PackedRadixIndexLayout.nodeStride) else {
                    throw DatabaseFormatError.invalidSection(.searchNodes, "invalid edge child")
                }
                let first = nodes.readUInt32(at: childOffset + 8)
                let count = nodes.readUInt32(at: childOffset + 12)
                guard first < root.nameCount, count <= root.nameCount - first else {
                    throw DatabaseFormatError.invalidSection(.searchNodes, "invalid child ordinal range")
                }
                return RadixPrefixMatch(
                    range: first..<first + count,
                    terminal: nil
                )
            }
            guard labelIndex == labelLength else {
                return nil
            }
            if isLeaf {
                guard queryOffset == query.count else {
                    return nil
                }
                return RadixPrefixMatch(
                    range: leafOrdinal..<leafOrdinal + 1,
                    terminal: leafOrdinal
                )
            }
            node = child
        }
    }

    private func findEdge(first: Int, count: Int, firstByte: UInt8) throws -> Int? {
        guard
            edges.containsRange(
                offset: first * PackedRadixIndexLayout.edgeStride,
                length: count * PackedRadixIndexLayout.edgeStride
            )
        else {
            throw DatabaseFormatError.invalidSection(.searchEdges, "invalid edge range")
        }
        if count <= 8 {
            for index in first..<first + count {
                let byte = edges[index * PackedRadixIndexLayout.edgeStride + 10]
                if byte == firstByte {
                    return index
                }
                if byte > firstByte {
                    return nil
                }
            }
            return nil
        }
        var low = first
        var high = first + count
        while low < high {
            let middle = low + (high - low) / 2
            let byte = edges[middle * PackedRadixIndexLayout.edgeStride + 10]
            if byte < firstByte {
                low = middle + 1
            } else {
                high = middle
            }
        }
        guard low < first + count,
            edges[low * PackedRadixIndexLayout.edgeStride + 10] == firstByte
        else {
            return nil
        }
        return low
    }

    private func addAreaPath(
        scope: SearchFilterScope,
        area: UInt32,
        root: RadixIndexRoot,
        match: RadixPrefixMatch,
        onlyExact: Bool,
        queryCharacters: Int,
        countryFilter: UInt16?,
        keySet: inout SearchPathKeySet,
        paths: inout [SearchTraversalPath],
        frontier: inout SearchFrontierHeap,
        results: inout TopKResultHeap
    ) throws {
        let key =
            UInt64(scope.rawValue) << 56
            | UInt64(root.indexID) << 40
            | UInt64(area)
        guard keySet.insert(key),
            let bucket = try areaBucket(scope: scope, indexID: root.indexID, area: area)
        else {
            return
        }
        let desiredRange =
            onlyExact
            ? match.terminal!..<match.terminal! + 1
            : match.range
        let lower = try areaLowerBound(
            scope: scope,
            bucket: bucket,
            ordinal: desiredRange.lowerBound
        )
        let upper = try areaLowerBound(
            scope: scope,
            bucket: bucket,
            ordinal: desiredRange.upperBound
        )
        guard lower < upper else {
            return
        }
        let path = SearchTraversalPath(
            scope: scope,
            root: root,
            area: area,
            itemStart: bucket.entryStart,
            itemCount: bucket.entryCount,
            treeStart: bucket.treeStart,
            treeLeafBase: bucket.treeLeafBase,
            terminal: match.terminal,
            countryFilter: countryFilter
        )
        let pathIndex = paths.count
        if paths.isEmpty { paths.reserveCapacity(8) }
        paths.append(path)
        try addRange(
            path: path,
            pathIndex: pathIndex,
            range: lower..<upper,
            queryCharacters: queryCharacters,
            onlyExact: onlyExact,
            frontier: &frontier,
            results: &results
        )
    }

    private func addRange(
        path: SearchTraversalPath,
        pathIndex: Int,
        range: Range<UInt32>,
        queryCharacters: Int,
        onlyExact: Bool,
        frontier: inout SearchFrontierHeap,
        results: inout TopKResultHeap
    ) throws {
        guard range.upperBound <= path.itemCount else {
            throw DatabaseFormatError.invalidSection(.searchNameMetadata, "invalid traversal range")
        }
        let leafSize = UInt32(PackedRadixIndexLayout.namesPerLeaf)
        let firstFull = (range.lowerBound + leafSize - 1) / leafSize
        let lastFull = range.upperBound / leafSize
        let firstBoundaryEnd = min(range.upperBound, firstFull * leafSize)
        if range.lowerBound < firstBoundaryEnd {
            try scanItems(
                path: path,
                range: range.lowerBound..<firstBoundaryEnd,
                queryCharacters: queryCharacters,
                results: &results
            )
        }
        let lastBoundaryStart = max(firstBoundaryEnd, lastFull * leafSize)
        if lastBoundaryStart < range.upperBound {
            try scanItems(
                path: path,
                range: lastBoundaryStart..<range.upperBound,
                queryCharacters: queryCharacters,
                results: &results
            )
        }
        guard firstFull < lastFull else {
            return
        }
        var left = path.treeLeafBase + firstFull
        var right = path.treeLeafBase + lastFull
        while left < right {
            if left & 1 == 1 {
                try addTreeNode(
                    path: path,
                    pathIndex: pathIndex,
                    node: left,
                    queryCharacters: queryCharacters,
                    onlyExact: onlyExact,
                    frontier: &frontier
                )
                left += 1
            }
            if right & 1 == 1 {
                right -= 1
                try addTreeNode(
                    path: path,
                    pathIndex: pathIndex,
                    node: right,
                    queryCharacters: queryCharacters,
                    onlyExact: onlyExact,
                    frontier: &frontier
                )
            }
            left /= 2
            right /= 2
        }
    }

    private func addTreeNode(
        path: SearchTraversalPath,
        pathIndex: Int,
        node: UInt32,
        queryCharacters: Int,
        onlyExact: Bool,
        frontier: inout SearchFrontierHeap
    ) throws {
        let tree = treeBytes(scope: path.scope)
        let offset = (Int(path.treeStart) + Int(node)) * PackedRadixIndexLayout.treeNodeStride
        let bound = PackedRadixIndexLayout.rankUpperBound(
            bytes: tree,
            offset: offset,
            queryCharacters: queryCharacters,
            onlyExact: onlyExact
        )
        guard bound.isFinite else {
            return
        }
        frontier.insert(
            SearchFrontierItem(
                upperBound: bound,
                pathIndex: pathIndex,
                node: node
            )
        )
    }

    private func scanItems(
        path: SearchTraversalPath,
        range: Range<UInt32>,
        queryCharacters: Int,
        results: inout TopKResultHeap
    ) throws {
        let entries = path.scope == .global ? nil : entryBytes(scope: path.scope)
        for item in range {
            let ordinal: UInt32
            let maximumRank: Float?
            if let entries {
                let offset = (Int(path.itemStart) + Int(item)) * PackedRadixIndexLayout.areaEntryStride
                ordinal = entries.readUInt32(at: offset)
                maximumRank = PackedRadixIndexLayout.decodeRankBound(entries.readUInt16(at: offset + 4))
            } else {
                ordinal = item
                maximumRank = nil
            }
            guard ordinal < path.root.nameCount else {
                throw DatabaseFormatError.invalidSection(.searchNameMetadata, "invalid name ordinal")
            }
            let metadataOffset = (Int(path.root.nameBase) + Int(ordinal)) * PackedRadixIndexLayout.nameMetadataStride
            let characterCount = Int(metadata.readUInt16(at: metadataOffset + 8))
            let boost = scoreBoost(
                characterCount: characterCount,
                queryCharacters: queryCharacters,
                isExact: ordinal == path.terminal
            )
            if let maximumRank, results.isFull, let worst = results.worst,
                maximumRank + boost < worst.score
            {
                continue
            }
            try scanName(path: path, metadataOffset: metadataOffset, boost: boost, results: &results)
        }
    }

    private func scanName(
        path: SearchTraversalPath,
        metadataOffset: Int,
        boost: Float,
        results: inout TopKResultHeap
    ) throws {
        results.diagnostics?.namesExamined += 1
        let postingStart = Int(metadata.readUInt32(at: metadataOffset))
        let postingCount = Int(metadata.readUInt32(at: metadataOffset + 4))
        guard
            postings.containsRange(
                offset: postingStart * PackedRadixIndexLayout.postingStride,
                length: postingCount * PackedRadixIndexLayout.postingStride
            )
        else {
            throw DatabaseFormatError.invalidSection(.searchPostings, "invalid posting range")
        }
        let country = path.scope == .country ? UInt16(exactly: path.area) : path.countryFilter
        for postingIndex in 0..<postingCount {
            results.diagnostics?.postingsExamined += 1
            let offset =
                (postingStart + postingIndex) * PackedRadixIndexLayout.postingStride
            let row = postings.readUInt32(at: offset)
            let rank = Float(bitPattern: postings.readUInt32(at: offset + 4))
            guard Int(row) < recordCount, rank.isFinite else {
                throw DatabaseFormatError.invalidSection(.searchPostings, "invalid posting row or rank")
            }
            let score = rank + boost
            if results.isFull, let worst = results.worst, score < worst.score {
                break
            }
            if let country,
                postings.readUInt16(at: offset + 8) != country
            {
                results.diagnostics?.postingsRejectedByGeography += 1
                continue
            }
            if path.scope == .admin, postings.readUInt32(at: offset + 10) != path.area {
                results.diagnostics?.postingsRejectedByGeography += 1
                continue
            }
            let rowIndex = Int(row)
            results.insert(
                row: row,
                id: Int32(
                    bitPattern: rowIDs.readUInt32(
                        at: rowIndex * LocationRecordView.stride
                    )
                ),
                score: score,
                sources: MatchSources(rawValue: postings.readUInt16(at: offset + 14))
            )
        }
    }

    private func scoreBoost(
        characterCount: Int,
        queryCharacters: Int,
        isExact: Bool
    ) -> Float {
        SearchScorer.boost(characterCount: characterCount, queryCharacters: queryCharacters, isExact: isExact)
    }

    private func areaBucket(
        scope: SearchFilterScope,
        indexID: UInt16,
        area: UInt32
    ) throws -> AreaOrdinalView? {
        let bytes = scope == .country ? countryBuckets : adminBuckets
        let count = scope == .country ? countryBucketCount : adminBucketCount
        var low = 0
        var high = count
        while low < high {
            let middle = low + (high - low) / 2
            let offset = middle * PackedRadixIndexLayout.areaBucketStride
            let candidateIndex = bytes.readUInt16(at: offset)
            let candidateArea = bytes.readUInt32(at: offset + 4)
            if candidateIndex < indexID
                || (candidateIndex == indexID && candidateArea < area)
            {
                low = middle + 1
            } else {
                high = middle
            }
        }
        guard low < count else {
            return nil
        }
        let offset = low * PackedRadixIndexLayout.areaBucketStride
        guard
            bytes.readUInt16(at: offset) == indexID,
            bytes.readUInt32(at: offset + 4) == area
        else {
            return nil
        }
        let bucket = AreaOrdinalView(
            indexID: indexID,
            area: area,
            entryStart: bytes.readUInt32(at: offset + 8),
            entryCount: bytes.readUInt32(at: offset + 12),
            treeStart: bytes.readUInt32(at: offset + 16),
            treeLeafBase: bytes.readUInt32(at: offset + 20)
        )
        let start = Int(bucket.entryStart)
        let items = Int(bucket.entryCount)
        let leaves = Int(bucket.treeLeafBase)
        guard bucket.entryCount <= 0x7fff_ffff,
            entryBytes(scope: scope).containsRange(offset: start * 6, length: items * 6),
            leaves > 0, leaves & (leaves - 1) == 0, leaves >= (items + 63) / 64,
            treeBytes(scope: scope).containsRange(offset: Int(bucket.treeStart) * 24, length: leaves * 2 * 24)
        else { throw DatabaseFormatError.invalidSection(.searchCountryBuckets, "invalid area view") }
        return bucket
    }

    private func areaLowerBound(
        scope: SearchFilterScope,
        bucket: AreaOrdinalView,
        ordinal: UInt32
    ) throws -> UInt32 {
        let bytes = entryBytes(scope: scope)
        var low: UInt32 = 0
        var high = bucket.entryCount
        while low < high {
            let middle = low + (high - low) / 2
            let offset =
                (Int(bucket.entryStart) + Int(middle)) * PackedRadixIndexLayout.areaEntryStride
            if bytes.readUInt32(at: offset) < ordinal {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    private func entryBytes(scope: SearchFilterScope) -> UnsafeRawBufferPointer {
        return scope == .country ? countryEntries : adminEntries
    }

    private func treeBytes(scope: SearchFilterScope) -> UnsafeRawBufferPointer {
        switch scope {
        case .global:
            return globalTrees
        case .country:
            return countryTrees
        case .admin:
            return adminTrees
        }
    }
}
