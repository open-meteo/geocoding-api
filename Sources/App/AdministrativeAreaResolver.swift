import Foundation

/// Resolves country and first-level administrative-area aliases.
struct AdministrativeAreaResolver: Sendable {
    struct Resolution: Sendable {
        var admin1IDs: Set<Int32>
        var countryCodes: Set<String>

        init(
            admin1IDs: Set<Int32> = [],
            countryCodes: Set<String> = []
        ) {
            self.admin1IDs = admin1IDs
            self.countryCodes = countryCodes
        }

        var isEmpty: Bool {
            return admin1IDs.isEmpty && countryCodes.isEmpty
        }
    }

    private let database: GeocodingDatabase
    private let recordCount: Int

    init(database: GeocodingDatabase) {
        self.database = database
        recordCount = Int(
            database.sectionDescriptor(.administrativeAliasRecords).count
        )
    }

    func resolve(
        _ value: String,
        languageID: UInt16,
        countryCode: String?
    ) -> Resolution {
        let normalized = Self.normalize(value)
        let countryFilter = countryCode.flatMap(GeocodingDatabase.countryValue)
        if countryCode != nil, countryFilter == nil {
            return Resolution()
        }
        if let result = lookup(
            kind: .abbreviation,
            languageID: 0,
            normalized: normalized,
            countryFilter: countryFilter
        ), !result.isEmpty {
            return result
        }
        var result =
            lookup(
                kind: .common,
                languageID: 0,
                normalized: normalized,
                countryFilter: countryFilter
            ) ?? Resolution()
        if let localized = lookup(
            kind: .localized,
            languageID: languageID,
            normalized: normalized,
            countryFilter: countryFilter
        ) {
            result.admin1IDs.formUnion(localized.admin1IDs)
            result.countryCodes.formUnion(localized.countryCodes)
        }
        return result
    }

    private func lookup(
        kind: AdministrativeAliasKind,
        languageID: UInt16,
        normalized: String,
        countryFilter: UInt16?
    ) -> Resolution? {
        func find(_ query: borrowing Span<UInt8>) -> Int? {
            var low = 0
            var high = recordCount
            while low < high {
                let middle = low + (high - low) / 2
                let comparison = compareRecord(
                    at: middle,
                    kind: kind,
                    languageID: languageID,
                    query: query
                )
                if comparison < 0 {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            guard
                low < recordCount,
                compareRecord(
                    at: low,
                    kind: kind,
                    languageID: languageID,
                    query: query
                ) == 0
            else {
                return nil
            }
            return low
        }

        let record: Int?
        if let found = normalized.utf8.withContiguousStorageIfAvailable({
            find(Span(_unsafeElements: $0))
        }) {
            record = found
        } else {
            let copy = Array(normalized.utf8)
            record = copy.withUnsafeBufferPointer {
                find(Span(_unsafeElements: $0))
            }
        }
        guard let record else {
            return nil
        }

        let records = database.rawSection(.administrativeAliasRecords)
        let candidates = database.rawSection(.administrativeAliasCandidates)
        let offset = record * AdministrativeAliasIndexLayout.recordStride
        let start = Int(records.readUInt32(at: offset + 8))
        let count = Int(records.readUInt16(at: offset + 12))
        var result = Resolution()
        for index in start..<start + count {
            let candidateOffset =
                index * AdministrativeAliasIndexLayout.candidateStride
            let country = candidates.readUInt16(at: candidateOffset + 4)
            guard countryFilter == nil || countryFilter == country else {
                continue
            }
            let admin1ID = candidates.readUInt32(at: candidateOffset)
            if admin1ID == 0 {
                result.countryCodes.insert(
                    GeocodingDatabase.countryString(country)
                )
            } else {
                result.admin1IDs.insert(Int32(bitPattern: admin1ID))
            }
        }
        return result
    }

    private func compareRecord(
        at index: Int,
        kind: AdministrativeAliasKind,
        languageID: UInt16,
        query: borrowing Span<UInt8>
    ) -> Int {
        let records = database.rawSection(.administrativeAliasRecords)
        let strings = database.rawSection(.administrativeAliasStrings)
        let offset = index * AdministrativeAliasIndexLayout.recordStride
        let candidateKind = records[offset]
        if candidateKind != kind.rawValue {
            return candidateKind < kind.rawValue ? -1 : 1
        }
        let candidateLanguage = records.readUInt16(at: offset + 2)
        if candidateLanguage != languageID {
            return candidateLanguage < languageID ? -1 : 1
        }
        let stringOffset = Int(records.readUInt32(at: offset + 4))
        let length = Int(strings.readUInt32(at: stringOffset))
        let candidate = UnsafeRawBufferPointer(
            rebasing: strings[
                stringOffset + 4..<stringOffset + 4 + length
            ]
        )
        let commonCount = min(candidate.count, query.count)
        for byte in 0..<commonCount where candidate[byte] != query[byte] {
            return candidate[byte] < query[byte] ? -1 : 1
        }
        if candidate.count == query.count {
            return 0
        }
        return candidate.count < query.count ? -1 : 1
    }

    static func normalize(_ value: String) -> String {
        return SearchTextNormalizer.foldAndLowercase(
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

}
