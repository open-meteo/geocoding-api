import Foundation

extension GeocodingDatabase {
    /// Recompute every leaf and parent. Range validation runs before this verifier.
    static func validateRankSummaries(
        header: DatabaseFileHeader,
        sections: [DatabaseSectionKind: UnsafeRawBufferPointer],
        mappedFile: MappedFile
    ) throws {
        let metadata = sections[.searchNameMetadata]!
        let postings = sections[.searchPostings]!
        let roots = sections[.searchRoots]!
        var nameBases = [UInt16: Int]()

        func nameSummary(_ ordinal: Int, country: UInt16? = nil, admin: UInt32? = nil) throws -> (Float, UInt16) {
            let offset = ordinal * PackedRadixIndexLayout.nameMetadataStride
            let start = Int(metadata.readUInt32(at: offset))
            let count = Int(metadata.readUInt32(at: offset + 4))
            let characters = metadata.readUInt16(at: offset + 8)
            for posting in start..<start + count {
                let base = posting * PackedRadixIndexLayout.postingStride
                if let country, postings.readUInt16(at: base + 8) != country { continue }
                if let admin, postings.readUInt32(at: base + 10) != admin { continue }
                return (Float(bitPattern: postings.readUInt32(at: base + 4)), characters)
            }
            throw DatabaseFormatError.invalidSection(.searchNameMetadata, "name/view has no matching postings")
        }

        func verifyTree(
            kind: DatabaseSectionKind,
            start: Int,
            leafBase: Int,
            itemCount: Int,
            item: (Int) throws -> (Float, UInt16)
        ) throws {
            let bytes = sections[kind]!
            let bins = PackedRadixIndexLayout.rankBinCount
            let empty = PackedRadixIndexLayout.emptyRankBound
            func stored(_ node: Int, _ bin: Int) -> UInt16 {
                bytes.readUInt16(at: (start + node) * bins * 2 + bin * 2)
            }
            for leaf in 0..<leafBase {
                var expected = LengthBinnedRankBounds()
                let lower = leaf * PackedRadixIndexLayout.namesPerLeaf
                let upper = min(itemCount, lower + PackedRadixIndexLayout.namesPerLeaf)
                if lower < upper {
                    for index in lower..<upper {
                        let (rank, length) = try item(index)
                        expected.insert(rank: rank, characterCount: length)
                    }
                }
                for bin in 0..<bins where stored(leafBase + leaf, bin) != expected.values[bin] {
                    throw DatabaseFormatError.invalidSection(kind, "incorrect rank leaf bound")
                }
            }
            if leafBase > 1 {
                for node in 1..<leafBase {
                    for bin in 0..<bins {
                        let lhs = stored(node * 2, bin)
                        let rhs = stored(node * 2 + 1, bin)
                        let expected = lhs == empty ? rhs : rhs == empty ? lhs : max(lhs, rhs)
                        guard stored(node, bin) == expected else {
                            throw DatabaseFormatError.invalidSection(kind, "incorrect rank parent bound")
                        }
                    }
                }
            }
        }

        for index in 0..<Int(header.sections[.searchRoots]!.count) {
            mappedFile.releaseResidentPages()
            let offset = index * PackedRadixIndexLayout.rootStride
            let id = roots.readUInt16(at: offset)
            let nameBase = Int(roots.readUInt32(at: offset + 8))
            let count = Int(roots.readUInt32(at: offset + 12))
            nameBases[id] = nameBase
            try verifyTree(
                kind: .searchGlobalTrees,
                start: Int(roots.readUInt32(at: offset + 16)),
                leafBase: Int(roots.readUInt32(at: offset + 20)),
                itemCount: count
            ) {
                try nameSummary(nameBase + $0)
            }
        }
        for (bucketKind, entryKind, treeKind) in [
            (
                DatabaseSectionKind.searchCountryBuckets, DatabaseSectionKind.searchCountryEntries,
                DatabaseSectionKind.searchCountryTrees
            ),
            (.searchAdminBuckets, .searchAdminEntries, .searchAdminTrees),
        ] {
            let buckets = sections[bucketKind]!
            let entries = sections[entryKind]!
            for index in 0..<Int(header.sections[bucketKind]!.count) {
                if index.isMultiple(of: 128) { mappedFile.releaseResidentPages() }
                let offset = index * PackedRadixIndexLayout.areaBucketStride
                let nameBase = nameBases[buckets.readUInt16(at: offset)]!
                let area = buckets.readUInt32(at: offset + 4)
                let first = Int(buckets.readUInt32(at: offset + 8))
                let count = Int(buckets.readUInt32(at: offset + 12))
                try verifyTree(
                    kind: treeKind,
                    start: Int(buckets.readUInt32(at: offset + 16)),
                    leafBase: Int(buckets.readUInt32(at: offset + 20)),
                    itemCount: count
                ) { item in
                    let entry = (first + item) * PackedRadixIndexLayout.areaEntryStride
                    let ordinal = Int(entries.readUInt32(at: entry))
                    let summary = try nameSummary(
                        nameBase + ordinal,
                        country: bucketKind == .searchCountryBuckets ? UInt16(exactly: area) : nil,
                        admin: bucketKind == .searchAdminBuckets ? area : nil
                    )
                    guard entries.readUInt16(at: entry + 4) == PackedRadixIndexLayout.encodeRankBound(summary.0) else {
                        throw DatabaseFormatError.invalidSection(entryKind, "incorrect area rank bound")
                    }
                    return summary
                }
            }
        }
    }
}
