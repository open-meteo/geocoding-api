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
    let path: SearchTraversalPath
    let node: UInt32
}

private struct SearchFrontierHeap {
    private var values = [SearchFrontierItem]()

    mutating func insert(_ value: SearchFrontierItem) {
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

private struct RankedSearchResult {
    let row: UInt32
    let id: Int32
    var score: Float
}

private struct TopKResultHeap {
    let capacity: Int
    private var heap = [RankedSearchResult]()
    private var indexByRow = [UInt32: Int]()

    init(capacity: Int) {
        self.capacity = capacity
        heap.reserveCapacity(capacity)
        indexByRow.reserveCapacity(capacity)
    }

    var isFull: Bool {
        return heap.count >= capacity
    }

    var worst: RankedSearchResult? {
        return heap.first
    }

    mutating func insert(row: UInt32, id: Int32, score: Float) {
        if let index = indexByRow[row] {
            guard score > heap[index].score else {
                return
            }
            heap[index].score = score
            siftDown(from: index)
            return
        }
        let value = RankedSearchResult(row: row, id: id, score: score)
        if heap.count < capacity {
            heap.append(value)
            indexByRow[row] = heap.count - 1
            siftUp(from: heap.count - 1)
            return
        }
        guard let worst, isBetter(value, than: worst) else {
            return
        }
        indexByRow.removeValue(forKey: worst.row)
        heap[0] = value
        indexByRow[row] = 0
        siftDown(from: 0)
    }

    func sorted() -> [(Int32, Float)] {
        return heap.map { ($0.id, $0.score) }.sorted {
            if $0.1 != $1.1 {
                return $0.1 > $1.1
            }
            return $0.0 < $1.0
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
        indexByRow[heap[lhs].row] = lhs
        indexByRow[heap[rhs].row] = rhs
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

final class PackedRadixSearchIndex: @unchecked Sendable {
    private let database: GeocodingDatabase
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
    private let roots: [UInt16: RadixIndexRoot]
    private let countryBucketCount: Int
    private let adminBucketCount: Int

    init(database: GeocodingDatabase) {
        self.database = database
        nodes = database.rawSection(.searchNodes)
        edges = database.rawSection(.searchEdges)
        labels = database.rawSection(.searchEdgeLabels)
        metadata = database.rawSection(.searchNameMetadata)
        postings = database.rawSection(.searchPostings)
        globalTrees = database.rawSection(.searchGlobalTrees)
        countryBuckets = database.rawSection(.searchCountryBuckets)
        countryEntries = database.rawSection(.searchCountryEntries)
        countryTrees = database.rawSection(.searchCountryTrees)
        adminBuckets = database.rawSection(.searchAdminBuckets)
        adminEntries = database.rawSection(.searchAdminEntries)
        adminTrees = database.rawSection(.searchAdminTrees)
        countryBucketCount = Int(
            database.sectionDescriptor(.searchCountryBuckets).count
        )
        adminBucketCount = Int(
            database.sectionDescriptor(.searchAdminBuckets).count
        )

        let bytes = database.rawSection(.searchRoots)
        let count = Int(database.sectionDescriptor(.searchRoots).count)
        var roots = [UInt16: RadixIndexRoot]()
        roots.reserveCapacity(count)
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
            roots[root.indexID] = root
        }
        self.roots = roots
    }

    func search(
        _ value: String,
        languageID: UInt16,
        count: Int,
        countryCode: String?,
        administrativeArea: AdministrativeAreaResolver.Resolution?
    ) -> [(Int32, Float)] {
        let normalized =
            value
            .folding(options: .diacriticInsensitive, locale: nil)
            .lowercased()
        let query = Array(normalized.utf8)
        guard !query.isEmpty else {
            return []
        }
        let queryCharacters = normalized.count
        let onlyExact = value.count <= 2
        let explicitCountry = countryCode.flatMap(GeocodingDatabase.countryValue)
        if countryCode != nil, explicitCountry == nil {
            return []
        }
        if let administrativeArea, administrativeArea.isEmpty {
            return []
        }

        let indexIDs: [UInt16] =
            languageID == UInt16.max ? [0] : [0, languageID + 1]
        var frontier = SearchFrontierHeap()
        var results = TopKResultHeap(capacity: count)
        var pathKeys = Set<UInt64>()

        for indexID in indexIDs {
            guard
                let root = roots[indexID],
                let match = prefixMatch(root: root, query: query)
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
                    addAreaPath(
                        scope: .country,
                        area: UInt32(country),
                        root: root,
                        match: match,
                        onlyExact: onlyExact,
                        queryCharacters: queryCharacters,
                        countryFilter: explicitCountry,
                        keySet: &pathKeys,
                        frontier: &frontier,
                        results: &results
                    )
                }
                for id in administrativeArea.admin1IDs where id > 0 {
                    addAreaPath(
                        scope: .admin,
                        area: UInt32(bitPattern: id),
                        root: root,
                        match: match,
                        onlyExact: onlyExact,
                        queryCharacters: queryCharacters,
                        countryFilter: explicitCountry,
                        keySet: &pathKeys,
                        frontier: &frontier,
                        results: &results
                    )
                }
            } else if let explicitCountry {
                addAreaPath(
                    scope: .country,
                    area: UInt32(explicitCountry),
                    root: root,
                    match: match,
                    onlyExact: onlyExact,
                    queryCharacters: queryCharacters,
                    countryFilter: explicitCountry,
                    keySet: &pathKeys,
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
                addRange(
                    path: path,
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
            if item.node < item.path.treeLeafBase {
                addTreeNode(
                    path: item.path,
                    node: item.node * 2,
                    queryCharacters: queryCharacters,
                    onlyExact: onlyExact,
                    frontier: &frontier
                )
                addTreeNode(
                    path: item.path,
                    node: item.node * 2 + 1,
                    queryCharacters: queryCharacters,
                    onlyExact: onlyExact,
                    frontier: &frontier
                )
            } else {
                let block = item.node - item.path.treeLeafBase
                let lower = block * UInt32(PackedRadixIndexLayout.namesPerLeaf)
                let upper = min(
                    item.path.itemCount,
                    lower + UInt32(PackedRadixIndexLayout.namesPerLeaf)
                )
                scanItems(
                    path: item.path,
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
        query: [UInt8]
    ) -> RadixPrefixMatch? {
        var node = root.rootNode
        var queryOffset = 0
        while true {
            let nodeOffset = Int(node) * PackedRadixIndexLayout.nodeStride
            if queryOffset == query.count {
                let first = nodes.readUInt32(at: nodeOffset + 8)
                let count = nodes.readUInt32(at: nodeOffset + 12)
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
                let edge = findEdge(
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
                let first = nodes.readUInt32(at: childOffset + 8)
                let count = nodes.readUInt32(at: childOffset + 12)
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

    private func findEdge(first: Int, count: Int, firstByte: UInt8) -> Int? {
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
        keySet: inout Set<UInt64>,
        frontier: inout SearchFrontierHeap,
        results: inout TopKResultHeap
    ) {
        let key =
            UInt64(scope.rawValue) << 56
            | UInt64(root.indexID) << 40
            | UInt64(area)
        guard keySet.insert(key).inserted,
            let bucket = areaBucket(scope: scope, indexID: root.indexID, area: area)
        else {
            return
        }
        let desiredRange =
            onlyExact
            ? match.terminal!..<match.terminal! + 1
            : match.range
        let lower = areaLowerBound(
            scope: scope,
            bucket: bucket,
            ordinal: desiredRange.lowerBound
        )
        let upper = areaLowerBound(
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
        addRange(
            path: path,
            range: lower..<upper,
            queryCharacters: queryCharacters,
            onlyExact: onlyExact,
            frontier: &frontier,
            results: &results
        )
    }

    private func addRange(
        path: SearchTraversalPath,
        range: Range<UInt32>,
        queryCharacters: Int,
        onlyExact: Bool,
        frontier: inout SearchFrontierHeap,
        results: inout TopKResultHeap
    ) {
        let leafSize = UInt32(PackedRadixIndexLayout.namesPerLeaf)
        let firstFull = (range.lowerBound + leafSize - 1) / leafSize
        let lastFull = range.upperBound / leafSize
        let firstBoundaryEnd = min(range.upperBound, firstFull * leafSize)
        if range.lowerBound < firstBoundaryEnd {
            scanItems(
                path: path,
                range: range.lowerBound..<firstBoundaryEnd,
                queryCharacters: queryCharacters,
                results: &results
            )
        }
        let lastBoundaryStart = max(firstBoundaryEnd, lastFull * leafSize)
        if lastBoundaryStart < range.upperBound {
            scanItems(
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
                addTreeNode(
                    path: path,
                    node: left,
                    queryCharacters: queryCharacters,
                    onlyExact: onlyExact,
                    frontier: &frontier
                )
                left += 1
            }
            if right & 1 == 1 {
                right -= 1
                addTreeNode(
                    path: path,
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
        node: UInt32,
        queryCharacters: Int,
        onlyExact: Bool,
        frontier: inout SearchFrontierHeap
    ) {
        let tree = treeBytes(scope: path.scope)
        let offset = Int(path.treeStart + node) * PackedRadixIndexLayout.treeNodeStride
        var summary = LengthBinnedRankBounds()
        for bin in 0..<PackedRadixIndexLayout.rankBinCount {
            summary.values[bin] = tree.readUInt16(at: offset + bin * 2)
        }
        let bound = summary.upperBound(
            queryCharacters: queryCharacters,
            onlyExact: onlyExact
        )
        guard bound.isFinite else {
            return
        }
        frontier.insert(
            SearchFrontierItem(upperBound: bound, path: path, node: node)
        )
    }

    private func scanItems(
        path: SearchTraversalPath,
        range: Range<UInt32>,
        queryCharacters: Int,
        results: inout TopKResultHeap
    ) {
        for item in range {
            let ordinal: UInt32
            if path.scope == .global {
                ordinal = item
            } else {
                let entries = entryBytes(scope: path.scope)
                let offset =
                    Int(path.itemStart + item) * PackedRadixIndexLayout.areaEntryStride
                ordinal = entries.readUInt32(at: offset)
                let maximumRank = PackedRadixIndexLayout.decodeRankBound(
                    entries.readUInt16(at: offset + 4)
                )
                let characterCount = nameCharacterCount(root: path.root, ordinal: ordinal)
                let boost = scoreBoost(
                    characterCount: characterCount,
                    queryCharacters: queryCharacters,
                    isExact: ordinal == path.terminal
                )
                if results.isFull, let worst = results.worst,
                    maximumRank + boost < worst.score
                {
                    continue
                }
            }
            scanName(
                path: path,
                ordinal: ordinal,
                queryCharacters: queryCharacters,
                results: &results
            )
        }
    }

    private func scanName(
        path: SearchTraversalPath,
        ordinal: UInt32,
        queryCharacters: Int,
        results: inout TopKResultHeap
    ) {
        let metadataOffset =
            Int(path.root.nameBase + ordinal) * PackedRadixIndexLayout.nameMetadataStride
        let postingStart = Int(metadata.readUInt32(at: metadataOffset))
        let postingCount = Int(metadata.readUInt32(at: metadataOffset + 4))
        let characterCount = Int(metadata.readUInt16(at: metadataOffset + 8))
        let boost = scoreBoost(
            characterCount: characterCount,
            queryCharacters: queryCharacters,
            isExact: ordinal == path.terminal
        )
        for postingIndex in 0..<postingCount {
            let offset =
                (postingStart + postingIndex) * PackedRadixIndexLayout.postingStride
            let row = postings.readUInt32(at: offset)
            let rank = Float(bitPattern: postings.readUInt32(at: offset + 4))
            let score = rank + boost
            if results.isFull, let worst = results.worst, score < worst.score {
                break
            }
            if let countryFilter = path.countryFilter,
                postings.readUInt16(at: offset + 8) != countryFilter
            {
                continue
            }
            switch path.scope {
            case .global:
                break
            case .country:
                guard UInt32(postings.readUInt16(at: offset + 8)) == path.area else {
                    continue
                }
            case .admin:
                guard postings.readUInt32(at: offset + 10) == path.area else {
                    continue
                }
            }
            let rowIndex = Int(row)
            results.insert(
                row: row,
                id: database.id(row: rowIndex),
                score: score
            )
        }
    }

    private func scoreBoost(
        characterCount: Int,
        queryCharacters: Int,
        isExact: Bool
    ) -> Float {
        if isExact {
            return 1.5
        }
        return 1.5 / Float(max(0, characterCount - queryCharacters) + 1)
    }

    private func nameCharacterCount(root: RadixIndexRoot, ordinal: UInt32) -> Int {
        let offset =
            Int(root.nameBase + ordinal) * PackedRadixIndexLayout.nameMetadataStride + 8
        return Int(metadata.readUInt16(at: offset))
    }

    private func areaBucket(
        scope: SearchFilterScope,
        indexID: UInt16,
        area: UInt32
    ) -> AreaOrdinalView? {
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
        return AreaOrdinalView(
            indexID: indexID,
            area: area,
            entryStart: bytes.readUInt32(at: offset + 8),
            entryCount: bytes.readUInt32(at: offset + 12),
            treeStart: bytes.readUInt32(at: offset + 16),
            treeLeafBase: bytes.readUInt32(at: offset + 20)
        )
    }

    private func areaLowerBound(
        scope: SearchFilterScope,
        bucket: AreaOrdinalView,
        ordinal: UInt32
    ) -> UInt32 {
        let bytes = entryBytes(scope: scope)
        var low: UInt32 = 0
        var high = bucket.entryCount
        while low < high {
            let middle = low + (high - low) / 2
            let offset =
                Int(bucket.entryStart + middle) * PackedRadixIndexLayout.areaEntryStride
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
