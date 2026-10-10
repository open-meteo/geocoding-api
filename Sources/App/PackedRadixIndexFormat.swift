import Foundation

enum PackedRadixIndexLayout {
    static let namesPerLeaf = 64
    static let rankBinLowerBounds = [
        0, 4, 8, 12, 16, 24, 32, 48, 64, 96, 128, 256,
    ]
    static let rankBinCount = 12
    static let emptyRankBound = UInt16.max
    static let rankScale: Float = 32_768

    static let rootStride = RadixRootLayout.stride
    static let nodeStride = RadixNodeLayout.stride
    static let edgeStride = RadixEdgeLayout.stride
    static let nameMetadataStride = NameMetadataLayout.stride
    static let postingStride = SearchPostingLayout.stride
    static let rankBoundStride = 2
    static let treeNodeStride = rankBinCount * rankBoundStride
    static let areaBucketStride = AreaBucketLayout.stride
    static let areaEntryStride = AreaEntryLayout.stride
    static let viewRecordStride = OrdinalViewLayout.stride

    static func rankBin(characterCount: UInt16) -> Int {
        let value = Int(characterCount)
        for index in stride(from: rankBinLowerBounds.count - 1, through: 0, by: -1) {
            if value >= rankBinLowerBounds[index] {
                return index
            }
        }
        return 0
    }

    static func encodeRankBound(_ rank: Float) -> UInt16 {
        guard rank.isFinite else {
            return emptyRankBound
        }
        precondition(rank >= 0 && rank <= Float(UInt16.max - 1) / rankScale, "Rank exceeds representable bound")
        let rounded = ceilf(max(0, rank) * rankScale)
        return UInt16(min(Float(UInt16.max - 1), rounded))
    }

    static func decodeRankBound(_ value: UInt16) -> Float {
        return value == emptyRankBound ? -.infinity : Float(value) / rankScale
    }

    static func rankBoosts(queryCharacters: Int, onlyExact: Bool) -> InlineArray<12, Float> {
        var boosts = InlineArray<12, Float>(repeating: 1.5)
        if !onlyExact {
            for index in boosts.indices {
                boosts[index] = SearchScorer.upperBoost(
                    minimumLength: max(queryCharacters, rankBinLowerBounds[index]),
                    queryCharacters: queryCharacters,
                    onlyExact: false
                )
            }
        }
        return boosts
    }

    static func rankUpperBound(
        bytes: borrowing Span<UInt8>,
        offset: Int,
        boosts: borrowing InlineArray<12, Float>
    ) -> Float {
        var result = -Float.infinity
        for index in 0..<rankBinCount {
            let rank = decodeRankBound(bytes.readUInt16(at: offset + index * rankBoundStride))
            guard rank.isFinite else {
                continue
            }
            result = max(result, rank + boosts[index])
        }
        return result
    }
}

struct LengthBinnedRankBounds {
    var values = InlineArray<12, UInt16>(
        repeating: PackedRadixIndexLayout.emptyRankBound,
    )

    mutating func insert(rank: Float, characterCount: UInt16) {
        let bin = PackedRadixIndexLayout.rankBin(characterCount: characterCount)
        let encoded = PackedRadixIndexLayout.encodeRankBound(rank)
        if values[bin] == PackedRadixIndexLayout.emptyRankBound || encoded > values[bin] {
            values[bin] = encoded
        }
    }

    mutating func combine(_ other: LengthBinnedRankBounds) {
        for index in values.indices {
            let rhs = other.values[index]
            if rhs == PackedRadixIndexLayout.emptyRankBound {
                continue
            }
            if values[index] == PackedRadixIndexLayout.emptyRankBound || rhs > values[index] {
                values[index] = rhs
            }
        }
    }

    func append(to output: inout [UInt16]) {
        for index in values.indices {
            output.append(values[index])
        }
    }

    func upperBound(queryCharacters: Int, onlyExact: Bool) -> Float {
        var result = -Float.infinity
        for index in values.indices {
            let rank = PackedRadixIndexLayout.decodeRankBound(values[index])
            guard rank.isFinite else {
                continue
            }
            let minimumLength = max(
                queryCharacters,
                PackedRadixIndexLayout.rankBinLowerBounds[index]
            )
            let boost = SearchScorer.upperBoost(
                minimumLength: minimumLength,
                queryCharacters: queryCharacters,
                onlyExact: onlyExact
            )
            result = max(result, rank + boost)
        }
        return result
    }
}

struct RadixIndexRoot: Sendable {
    let indexID: UInt16
    let rootNode: UInt32
    let nameBase: UInt32
    let nameCount: UInt32
    let treeStart: UInt32
    let treeLeafBase: UInt32
}

struct AreaOrdinalView {
    let indexID: UInt16
    let area: UInt32
    let entryStart: UInt32
    let entryCount: UInt32
    let treeStart: UInt32
    let treeLeafBase: UInt32
}
