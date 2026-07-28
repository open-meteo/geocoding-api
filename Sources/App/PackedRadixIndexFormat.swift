import Foundation

enum PackedRadixIndexLayout {
    static let namesPerLeaf = 64
    static let rankBinLowerBounds = [
        0, 4, 8, 12, 16, 24, 32, 48, 64, 96, 128, 256,
    ]
    static let rankBinCount = 12
    static let emptyRankBound = UInt16.max
    static let rankScale: Float = 32_768

    static let rootStride = 24
    static let nodeStride = 16
    static let edgeStride = 12
    static let nameMetadataStride = 12
    static let postingStride = 14
    static let treeNodeStride = rankBinCount * 2
    static let areaBucketStride = 28
    static let areaEntryStride = 6
    static let viewRecordStride = 16

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
        let rounded = ceilf(max(0, rank) * rankScale)
        return UInt16(min(Float(UInt16.max - 1), rounded))
    }

    static func decodeRankBound(_ value: UInt16) -> Float {
        return value == emptyRankBound ? -.infinity : Float(value) / rankScale
    }

    static func rankUpperBound(
        bytes: UnsafeRawBufferPointer,
        offset: Int,
        queryCharacters: Int,
        onlyExact: Bool
    ) -> Float {
        var result = -Float.infinity
        for index in 0..<rankBinCount {
            let rank = decodeRankBound(bytes.readUInt16(at: offset + index * 2))
            guard rank.isFinite else {
                continue
            }
            let minimumLength = max(
                queryCharacters,
                rankBinLowerBounds[index]
            )
            let boost: Float
            if onlyExact || minimumLength == queryCharacters {
                boost = 1.5
            } else {
                boost = 1.5 / Float(minimumLength - queryCharacters + 1)
            }
            result = max(result, rank + boost)
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
        output.reserveCapacity(output.count + PackedRadixIndexLayout.rankBinCount)
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
            let boost: Float
            if onlyExact {
                boost = 1.5
            } else if minimumLength == queryCharacters {
                boost = 1.5
            } else {
                boost = 1.5 / Float(minimumLength - queryCharacters + 1)
            }
            result = max(result, rank + boost)
        }
        return result
    }
}

struct RadixIndexRoot {
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
