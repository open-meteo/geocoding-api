import XCTest

@testable import App

final class AdministrativeAreaLookupTests: XCTestCase {
    private enum ID {
        static let india: Int32 = 1
        static let unitedStates: Int32 = 2
        static let indiana: Int32 = 3
        static let delhiIndia: Int32 = 4
        static let delhiAdministrativeArea: Int32 = 5
        static let delhiIndiana: Int32 = 6
        static let sharedIndia: Int32 = 7
        static let sharedUnitedStates: Int32 = 8
        static let puertoRico: Int32 = 9
        static let sanJuanMunicipality: Int32 = 10
        static let sanJuan: Int32 = 11
        static let guam: Int32 = 12
        static let dededoMunicipality: Int32 = 13
        static let dededoVillage: Int32 = 14
        static let hongKong: Int32 = 15
    }

    private enum LanguageID {
        static let english: Int32 = 1
        static let abbreviation: Int32 = 2
        static let german: Int32 = 5
    }

    func testExplicitCountryDisambiguatesCountryCodeFromADM1Abbreviation() {
        let lookup = AdministrativeAreaLookup(geonames: makeGeonames())

        let withoutCountry = lookup.resolve("IN", languageID: LanguageID.english)
        XCTAssertEqual(withoutCountry.admin1IDs, [ID.indiana])
        XCTAssertEqual(withoutCountry.countryCodes, [])

        let india = lookup.resolve("IN", languageID: LanguageID.english, countryCode: "IN")
        XCTAssertEqual(india.admin1IDs, [])
        XCTAssertEqual(india.countryCodes, ["IN"])

        let unitedStates = lookup.resolve("IN", languageID: LanguageID.english, countryCode: " us ")
        XCTAssertEqual(unitedStates.admin1IDs, [ID.indiana])
        XCTAssertEqual(unitedStates.countryCodes, [])

        let normalizedIndia = lookup.resolve("IN", languageID: LanguageID.english, countryCode: " in ")
        XCTAssertEqual(normalizedIndia.admin1IDs, [])
        XCTAssertEqual(normalizedIndia.countryCodes, ["IN"])

        XCTAssertTrue(
            lookup.resolve("IN", languageID: LanguageID.english, countryCode: "ZZ").isEmpty
        )
        XCTAssertTrue(
            lookup.resolve("IN", languageID: LanguageID.english, countryCode: "  ").isEmpty
        )
    }

    func testAliasCollisionsRemainDeduplicatedAndRespectCountryContext() {
        let lookup = AdministrativeAreaLookup(geonames: makeGeonames())

        XCTAssertEqual(
            lookup.resolve("Shared Region", languageID: LanguageID.english).admin1IDs,
            [ID.sharedIndia, ID.sharedUnitedStates]
        )
        XCTAssertEqual(
            lookup.resolve("Shared Region", languageID: LanguageID.english, countryCode: "IN").admin1IDs,
            [ID.sharedIndia]
        )
        XCTAssertEqual(
            lookup.resolve("Gemeinsam", languageID: LanguageID.german).admin1IDs,
            [ID.sharedIndia, ID.sharedUnitedStates]
        )
    }

    func testLanguageNeutralAliasesAreAvailableInEveryRequestedLanguage() {
        let lookup = AdministrativeAreaLookup(geonames: makeGeonames())

        let resolution = lookup.resolve("Republic of India", languageID: LanguageID.english)
        XCTAssertEqual(resolution.admin1IDs, [])
        XCTAssertEqual(resolution.countryCodes, ["IN"])
    }

    func testAllCountryFeatureCodesAreIndexed() {
        let featureCodes = ["PCLI", "PCLD", "PCLIX", "PCLS", "PCLF", "PCL"]
        let countryCodes = ["AA", "AB", "AC", "AD", "AE", "AF"]
        var geonames = GeocodingDatabase.Geonames()
        geonames.languages = ["en"]

        for (offset, featureCode) in featureCodes.enumerated() {
            let id = Int32(offset + 1)
            geonames.geonames[id] = makeGeoname(
                id: id,
                name: "\(featureCode) Territory",
                featureCode: featureCode,
                countryCode: countryCodes[offset],
                countryID: 0
            )
        }

        let lookup = AdministrativeAreaLookup(geonames: geonames)
        for (offset, featureCode) in featureCodes.enumerated() {
            let resolution = lookup.resolve(
                "\(featureCode) Territory",
                languageID: 0
            )
            XCTAssertEqual(resolution.admin1IDs, [])
            XCTAssertEqual(resolution.countryCodes, [countryCodes[offset]])

            let isoResolution = lookup.resolve(
                countryCodes[offset],
                languageID: 0,
                countryCode: countryCodes[offset].lowercased()
            )
            XCTAssertEqual(isoResolution.admin1IDs, [])
            XCTAssertEqual(isoResolution.countryCodes, [countryCodes[offset]])
        }

        geonames.geonames[100] = makeGeoname(
            id: 100,
            name: "No ISO Territory",
            featureCode: "PCLD",
            countryCode: "",
            countryID: 0
        )
        XCTAssertTrue(
            AdministrativeAreaLookup(geonames: geonames)
                .resolve("No ISO Territory", languageID: 0)
                .isEmpty
        )
    }

    func testDependentTerritoriesResolveWithoutCountryIDs() {
        let lookup = AdministrativeAreaLookup(geonames: makeGeonames())

        let puertoRico = lookup.resolve("Puerto Rico", languageID: LanguageID.english)
        XCTAssertEqual(puertoRico.admin1IDs, [])
        XCTAssertEqual(puertoRico.countryCodes, ["PR"])

        let guam = lookup.resolve(
            "Dededo Municipality",
            languageID: LanguageID.english,
            countryCode: "GU"
        )
        XCTAssertEqual(guam.admin1IDs, [ID.dededoMunicipality])
        XCTAssertEqual(guam.countryCodes, [])

        let hongKong = lookup.resolve(
            "Hong Kong",
            languageID: LanguageID.english,
            countryCode: "HK"
        )
        XCTAssertEqual(hongKong.admin1IDs, [])
        XCTAssertEqual(hongKong.countryCodes, ["HK"])
    }

    func testDatabaseSearchWithAndWithoutFilters() {
        let database = makeDatabase()
        let lookup = AdministrativeAreaLookup(geonames: database.geonames)

        XCTAssertEqual(
            database.search("Delhi", languageId: LanguageID.english, maxCount: 10).map(\.0),
            [ID.delhiIndia, ID.delhiIndiana]
        )
        XCTAssertEqual(
            database.search(
                "Delhi",
                languageId: LanguageID.english,
                maxCount: 10,
                countryCode: " in "
            ).map(\.0),
            [ID.delhiIndia]
        )
        XCTAssertEqual(
            database.search(
                "Delhi",
                languageId: LanguageID.english,
                maxCount: 10,
                administrativeArea: lookup.resolve(
                    "Indiana",
                    languageID: LanguageID.english
                )
            ).map(\.0),
            [ID.delhiIndiana]
        )
        XCTAssertEqual(
            database.search(
                "Delhi",
                languageId: LanguageID.english,
                maxCount: 10,
                countryCode: "IN",
                administrativeArea: lookup.resolve(
                    "IN",
                    languageID: LanguageID.english,
                    countryCode: "IN"
                )
            ).map(\.0),
            [ID.delhiIndia]
        )
        XCTAssertEqual(
            database.search(
                "San Juan",
                languageId: LanguageID.english,
                maxCount: 10,
                administrativeArea: lookup.resolve(
                    "Puerto Rico",
                    languageID: LanguageID.english
                )
            ).map(\.0),
            [ID.sanJuan]
        )
    }

    func testQualifierStopsAtNextComma() {
        let parsed = GeocodingapiController.parseSearchName(
            " Delhi, National Capital Territory of Delhi, IN "
        )

        XCTAssertEqual(parsed.name, "Delhi")
        XCTAssertEqual(parsed.areaName, "National Capital Territory of Delhi")
    }

    private func makeDatabase() -> GeocodingDatabase {
        let geonames = makeGeonames()
        let mainIndex = SearchTreeLoader()
        let languageIndexes = geonames.languages.map { _ in SearchTreeLoader() }

        for (id, geoname) in geonames.geonames
        where geonames.includeInSearchIndex(featureCode: geoname.featureCode) {
            mainIndex.add(geoname.name, id: id)
            for (languageID, alternativeName) in geoname.alternativeNames {
                languageIndexes[Int(languageID)].add(alternativeName, id: id)
            }
        }

        var database = GeocodingDatabase()
        database.geonames = geonames
        database.index = mainIndex.immutable()
        database.languageIndex = languageIndexes.map { $0.immutable() }
        return database
    }

    private func makeGeonames() -> GeocodingDatabase.Geonames {
        var geonames = GeocodingDatabase.Geonames()
        geonames.languages = ["", "en", "abbr", "icao", "iata", "de"]
        geonames.timezones = ["UTC"]
        geonames.geonames = [
            ID.india: makeGeoname(
                id: ID.india,
                name: "India",
                featureCode: "PCLI",
                countryCode: "IN",
                countryID: ID.india,
                alternativeNames: [0: "Republic of India"]
            ),
            ID.unitedStates: makeGeoname(
                id: ID.unitedStates,
                name: "United States",
                featureCode: "PCLI",
                countryCode: "US",
                countryID: ID.unitedStates
            ),
            ID.indiana: makeGeoname(
                id: ID.indiana,
                name: "Indiana",
                featureCode: "ADM1",
                countryCode: "US",
                countryID: ID.unitedStates,
                admin1ID: ID.indiana,
                alternativeNames: [LanguageID.abbreviation: "IN"]
            ),
            ID.delhiIndia: makeGeoname(
                id: ID.delhiIndia,
                name: "Delhi",
                featureCode: "PPLC",
                countryCode: "IN",
                countryID: ID.india,
                admin1ID: ID.delhiAdministrativeArea,
                ranking: 0.9
            ),
            ID.delhiAdministrativeArea: makeGeoname(
                id: ID.delhiAdministrativeArea,
                name: "National Capital Territory of Delhi",
                featureCode: "ADM1",
                countryCode: "IN",
                countryID: ID.india,
                admin1ID: ID.delhiAdministrativeArea,
                alternativeNames: [LanguageID.abbreviation: "DL"]
            ),
            ID.delhiIndiana: makeGeoname(
                id: ID.delhiIndiana,
                name: "Delhi",
                featureCode: "PPL",
                countryCode: "US",
                countryID: ID.unitedStates,
                admin1ID: ID.indiana,
                ranking: 0.4
            ),
            ID.sharedIndia: makeGeoname(
                id: ID.sharedIndia,
                name: "Shared Region",
                featureCode: "ADM1",
                countryCode: "IN",
                countryID: ID.india,
                admin1ID: ID.sharedIndia,
                alternativeNames: [
                    LanguageID.english: "Shared Region",
                    LanguageID.german: "Gemeinsam",
                ]
            ),
            ID.sharedUnitedStates: makeGeoname(
                id: ID.sharedUnitedStates,
                name: "Shared Region",
                featureCode: "ADM1",
                countryCode: "US",
                countryID: ID.unitedStates,
                admin1ID: ID.sharedUnitedStates,
                alternativeNames: [LanguageID.german: "Gemeinsam"]
            ),
            ID.puertoRico: makeGeoname(
                id: ID.puertoRico,
                name: "Puerto Rico",
                featureCode: "PCLD",
                countryCode: "PR",
                countryID: 0
            ),
            ID.sanJuanMunicipality: makeGeoname(
                id: ID.sanJuanMunicipality,
                name: "San Juan",
                featureCode: "ADM1",
                countryCode: "PR",
                countryID: 0,
                admin1ID: ID.sanJuanMunicipality
            ),
            ID.sanJuan: makeGeoname(
                id: ID.sanJuan,
                name: "San Juan",
                featureCode: "PPLA",
                countryCode: "PR",
                countryID: 0,
                admin1ID: ID.sanJuanMunicipality,
                ranking: 0.8
            ),
            ID.guam: makeGeoname(
                id: ID.guam,
                name: "Guam",
                featureCode: "PCLD",
                countryCode: "GU",
                countryID: 0
            ),
            ID.dededoMunicipality: makeGeoname(
                id: ID.dededoMunicipality,
                name: "Dededo Municipality",
                featureCode: "ADM1",
                countryCode: "GU",
                countryID: 0,
                admin1ID: ID.dededoMunicipality
            ),
            ID.dededoVillage: makeGeoname(
                id: ID.dededoVillage,
                name: "Dededo Village",
                featureCode: "PPL",
                countryCode: "GU",
                countryID: 0,
                admin1ID: ID.dededoMunicipality,
                ranking: 0.7
            ),
            ID.hongKong: makeGeoname(
                id: ID.hongKong,
                name: "Hong Kong",
                featureCode: "PCLS",
                countryCode: "HK",
                countryID: 0,
                ranking: 0.9
            ),
        ]
        return geonames
    }

    private func makeGeoname(
        id: Int32,
        name: String,
        featureCode: String,
        countryCode: String,
        countryID: Int32,
        admin1ID: Int32 = 0,
        ranking: Float = 0,
        alternativeNames: [Int32: String] = [:]
    ) -> GeocodingDatabase.Geoname {
        var geoname = GeocodingDatabase.Geoname()
        geoname.id = id
        geoname.name = name
        geoname.latitude = Float(id)
        geoname.longitude = Float(id)
        geoname.ranking = ranking
        geoname.featureCode = featureCode
        geoname.countryIso2 = countryCode
        geoname.countryID = countryID
        geoname.admin1ID = admin1ID
        geoname.alternativeNames = alternativeNames
        return geoname
    }
}
