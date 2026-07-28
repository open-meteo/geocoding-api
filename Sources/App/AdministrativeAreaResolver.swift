import Foundation

/// Resolves country and first-level administrative-area aliases.
struct AdministrativeAreaResolver {
    struct Resolution {
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

    private struct LocalizedAlias: Hashable {
        let languageID: UInt16
        let alias: String
    }

    private struct Candidate: Hashable {
        let admin1ID: Int32?
        let countryCode: String
    }

    private enum Matches {
        case single(Candidate)
        case multiple(Set<Candidate>)

        mutating func insert(_ candidate: Candidate) {
            switch self {
            case .single(let existing):
                if existing != candidate {
                    self = .multiple([existing, candidate])
                }
            case .multiple(var values):
                values.insert(candidate)
                self = .multiple(values)
            }
        }

        func add(
            to resolution: inout Resolution,
            countryCode: String?
        ) {
            func addCandidate(_ candidate: Candidate) {
                guard countryCode == nil || candidate.countryCode == countryCode else {
                    return
                }
                if let id = candidate.admin1ID {
                    resolution.admin1IDs.insert(id)
                } else if !candidate.countryCode.isEmpty {
                    resolution.countryCodes.insert(candidate.countryCode)
                }
            }
            switch self {
            case .single(let value):
                addCandidate(value)
            case .multiple(let values):
                for value in values {
                    addCandidate(value)
                }
            }
        }
    }

    private let common: [String: Matches]
    private let localized: [LocalizedAlias: Matches]
    private let abbreviations: [String: Matches]

    init(database: GeocodingDatabase) throws {
        let abbreviation = database.languageIDs["abbr"]
        let neutral = database.languageIDs[""]
        let english = database.languageIDs["en"]
        var common = [String: Matches]()
        var localized = [LocalizedAlias: Matches]()
        var abbreviations = [String: Matches]()

        func insert<Key: Hashable>(
            _ candidate: Candidate,
            key: Key,
            into values: inout [Key: Matches]
        ) {
            if var matches = values[key] {
                matches.insert(candidate)
                values[key] = matches
            } else {
                values[key] = .single(candidate)
            }
        }

        for row in 0..<database.recordCount {
            let feature = database.feature(row: row)
            let isCountry = Self.isCountry(feature)
            guard feature == "ADM1" || isCountry else {
                continue
            }
            let candidate = Candidate(
                admin1ID: isCountry ? nil : database.id(row: row),
                countryCode: database.countryISO2(row: row)
            )
            let canonical = Self.normalize(try database.canonicalName(row: row))
            if !canonical.isEmpty {
                insert(candidate, key: canonical, into: &common)
            }
            try database.forEachAlternateName(row: row) { languageID, name in
                let normalized = Self.normalize(name)
                guard !normalized.isEmpty else {
                    return
                }
                if languageID == abbreviation {
                    if isCountry {
                        insert(candidate, key: normalized, into: &common)
                    } else {
                        insert(candidate, key: normalized, into: &abbreviations)
                    }
                } else if languageID == neutral || languageID == english {
                    insert(candidate, key: normalized, into: &common)
                } else {
                    insert(
                        candidate,
                        key: LocalizedAlias(
                            languageID: languageID,
                            alias: normalized
                        ),
                        into: &localized
                    )
                }
            }
            if isCountry, !candidate.countryCode.isEmpty {
                insert(
                    candidate,
                    key: Self.normalize(candidate.countryCode),
                    into: &common
                )
            }
        }
        self.common = common
        self.localized = localized
        self.abbreviations = abbreviations
    }

    func resolve(
        _ value: String,
        languageID: UInt16,
        countryCode: String?
    ) -> Resolution {
        let normalized = Self.normalize(value)
        let country = countryCode.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        }
        if let abbreviation = abbreviations[normalized] {
            var result = Resolution()
            abbreviation.add(to: &result, countryCode: country)
            if !result.isEmpty {
                return result
            }
        }
        var result = Resolution()
        common[normalized]?.add(to: &result, countryCode: country)
        localized[
            LocalizedAlias(languageID: languageID, alias: normalized)
        ]?.add(to: &result, countryCode: country)
        return result
    }

    private static func normalize(_ value: String) -> String {
        return
            value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: .diacriticInsensitive, locale: nil)
            .lowercased()
    }

    private static func isCountry(_ feature: String) -> Bool {
        switch feature {
        case "PCLI", "PCLD", "PCLIX", "PCLS", "PCLF", "PCL":
            return true
        default:
            return false
        }
    }
}
