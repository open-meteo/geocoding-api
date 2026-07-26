import Foundation

/// Resolves exact names and abbreviations for first-level administrative areas and countries.
struct AdministrativeAreaLookup {
    struct Resolution {
        var admin1IDs: Set<Int32>
        var countryCodes: Set<String>

        init(admin1IDs: Set<Int32> = [], countryCodes: Set<String> = []) {
            self.admin1IDs = admin1IDs
            self.countryCodes = countryCodes
        }

        var isEmpty: Bool {
            return admin1IDs.isEmpty && countryCodes.isEmpty
        }
    }

    private struct LocalizedAlias: Hashable {
        let languageID: Int32
        let alias: String
    }

    private struct AliasCandidate: Hashable {
        let admin1ID: Int32?
        let countryCode: String
    }

    private enum AliasMatches {
        case single(AliasCandidate)
        case multiple(Set<AliasCandidate>)

        mutating func insert(_ candidate: AliasCandidate) {
            switch self {
            case .single(let existing):
                guard existing != candidate else {
                    return
                }
                self = .multiple([existing, candidate])
            case .multiple(var candidates):
                candidates.insert(candidate)
                self = .multiple(candidates)
            }
        }

        func formResolution(into resolution: inout Resolution, countryCode: String?) {
            func add(_ candidate: AliasCandidate) {
                guard countryCode == nil || candidate.countryCode == countryCode else {
                    return
                }
                if let admin1ID = candidate.admin1ID {
                    resolution.admin1IDs.insert(admin1ID)
                } else if !candidate.countryCode.isEmpty {
                    resolution.countryCodes.insert(candidate.countryCode)
                }
            }

            switch self {
            case .single(let candidate):
                add(candidate)
            case .multiple(let candidates):
                for candidate in candidates {
                    add(candidate)
                }
            }
        }

        func resolution(countryCode: String?) -> Resolution {
            var resolution = Resolution()
            formResolution(into: &resolution, countryCode: countryCode)
            return resolution
        }
    }

    private let idsByCommonAlias: [String: AliasMatches]
    private let idsByLocalizedAlias: [LocalizedAlias: AliasMatches]
    private let adm1IDsByAbbreviation: [String: AliasMatches]

    init(geonames: GeocodingDatabase.Geonames) {
        let abbreviationLanguageID = geonames.languages.firstIndex(of: "abbr").map(Int32.init)
        let englishLanguageID = geonames.languages.firstIndex(of: "en").map(Int32.init)
        var idsByCommonAlias = [String: AliasMatches]()
        var idsByLocalizedAlias = [LocalizedAlias: AliasMatches]()
        var adm1IDsByAbbreviation = [String: AliasMatches]()

        func add(_ alias: String, candidate: AliasCandidate, to index: inout [String: AliasMatches]) {
            let normalized = Self.normalize(alias)
            guard !normalized.isEmpty else {
                return
            }
            Self.insert(candidate, for: normalized, into: &index)
        }

        for (id, geoname) in geonames.geonames
        where geoname.featureCode == "ADM1" || Self.isCountry(featureCode: geoname.featureCode) {
            let isCountry = Self.isCountry(featureCode: geoname.featureCode)
            let candidate = AliasCandidate(
                admin1ID: isCountry ? nil : id,
                countryCode: Self.normalizeCountryCode(geoname.countryIso2)
            )
            add(geoname.name, candidate: candidate, to: &idsByCommonAlias)

            for (languageID, alternativeName) in geoname.alternativeNames {
                if languageID == abbreviationLanguageID {
                    if !isCountry {
                        add(alternativeName, candidate: candidate, to: &adm1IDsByAbbreviation)
                    } else {
                        add(alternativeName, candidate: candidate, to: &idsByCommonAlias)
                    }
                } else if languageID == englishLanguageID {
                    add(alternativeName, candidate: candidate, to: &idsByCommonAlias)
                } else {
                    let normalized = Self.normalize(alternativeName)
                    guard !normalized.isEmpty else {
                        continue
                    }
                    let key = LocalizedAlias(languageID: languageID, alias: normalized)
                    Self.insert(candidate, for: key, into: &idsByLocalizedAlias)
                }
            }

            if isCountry {
                add(geoname.countryIso2, candidate: candidate, to: &idsByCommonAlias)
            }
        }

        self.idsByCommonAlias = idsByCommonAlias
        self.idsByLocalizedAlias = idsByLocalizedAlias
        self.adm1IDsByAbbreviation = adm1IDsByAbbreviation
    }

    func resolve(_ value: String, languageID: Int32, countryCode: String? = nil) -> Resolution {
        let normalized = Self.normalize(value)
        let normalizedCountryCode = countryCode.map(Self.normalizeCountryCode)

        // In a comma qualifier, an ADM1 abbreviation is more specific than a colliding country code.
        if let adm1Matches = adm1IDsByAbbreviation[normalized] {
            let resolution = adm1Matches.resolution(countryCode: normalizedCountryCode)
            if !resolution.isEmpty {
                return resolution
            }
        }

        var resolution = Resolution()
        idsByCommonAlias[normalized]?.formResolution(
            into: &resolution,
            countryCode: normalizedCountryCode
        )
        let localizedAlias = LocalizedAlias(languageID: languageID, alias: normalized)
        idsByLocalizedAlias[localizedAlias]?.formResolution(
            into: &resolution,
            countryCode: normalizedCountryCode
        )
        return resolution
    }

    private static func insert<Key: Hashable>(
        _ candidate: AliasCandidate,
        for key: Key,
        into index: inout [Key: AliasMatches]
    ) {
        if var matches = index[key] {
            matches.insert(candidate)
            index[key] = matches
        } else {
            index[key] = .single(candidate)
        }
    }

    private static func normalize(_ value: String) -> String {
        return
            value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: .diacriticInsensitive, locale: nil)
            .lowercased()
    }

    private static func normalizeCountryCode(_ value: String) -> String {
        return value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private static func isCountry(featureCode: String) -> Bool {
        switch featureCode {
        case "PCLI", "PCLD", "PCLIX", "PCLS", "PCLF", "PCL":
            return true
        default:
            return false
        }
    }
}
