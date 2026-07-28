import Foundation
import Logging
import XCTest

@testable import App

final class GeocodingDatabaseTests: XCTestCase {
    private var temporaryDirectories = [URL]()

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    func testBuildLoadSearchAndLocalizedResponse() throws {
        let paths = try makeFixture(name: "primary")
        try GeocodingDatabaseBuilder(
            logger: Logger(label: "database-test"),
            options: DatabaseBuildOptions(memoryLimitBytes: 64 << 20, workers: 1),
            paths: paths
        ).build()

        let database = try GeocodingDatabase(url: paths.databaseFile)
        XCTAssertEqual(database.recordCount, 8)
        XCTAssertEqual(database.header.maximumGeonameID, 220)
        XCTAssertTrue(database.header.sections.values.allSatisfy { $0.offset % 4096 == 0 })

        let english = try XCTUnwrap(database.languageIDs["en"])
        let german = try XCTUnwrap(database.languageIDs["de"])
        let response = try XCTUnwrap(database.response(id: 120, languageID: german))
        XCTAssertEqual(response.name, "Frühlingsfeld")
        XCTAssertEqual(response.country, "Testland")
        XCTAssertEqual(response.admin1, "Nordregion")
        XCTAssertEqual(response.postcodes, ["1234"])
        XCTAssertEqual(response.timezone, "Europe/Zurich")

        let exact = database.searchIndex.search(
            "Springfield",
            languageID: english,
            count: 10,
            countryCode: nil,
            administrativeArea: nil
        )
        XCTAssertEqual(exact.map(\.0), [120, 220, 121])
        XCTAssertGreaterThan(exact[0].1, exact[1].1)

        let prefix = database.searchIndex.search(
            "Spring",
            languageID: english,
            count: 10,
            countryCode: "TL",
            administrativeArea: nil
        )
        XCTAssertEqual(prefix.map(\.0), [120, 121])

        let germanSearch = database.searchIndex.search(
            "Fruhl",
            languageID: german,
            count: 10,
            countryCode: nil,
            administrativeArea: nil
        )
        XCTAssertEqual(germanSearch.map(\.0), [120])

        let postcode = database.searchIndex.search(
            "1234",
            languageID: english,
            count: 10,
            countryCode: nil,
            administrativeArea: nil
        )
        XCTAssertEqual(postcode.map(\.0), [120])

        let historic = database.searchIndex.search(
            "Old Springfield",
            languageID: english,
            count: 10,
            countryCode: nil,
            administrativeArea: nil
        )
        XCTAssertTrue(historic.isEmpty)

        let lookup = try AdministrativeAreaResolver(database: database)
        let area = lookup.resolve("NR", languageID: english, countryCode: "TL")
        let filtered = database.searchIndex.search(
            "Spring",
            languageID: english,
            count: 10,
            countryCode: nil,
            administrativeArea: area
        )
        XCTAssertEqual(filtered.map(\.0), [120, 121])

        let filteredByCountryAndArea = database.searchIndex.search(
            "Spring",
            languageID: english,
            count: 10,
            countryCode: "TL",
            administrativeArea: area
        )
        XCTAssertEqual(filteredByCountryAndArea.map(\.0), [120, 121])

        let excludedByCountry = database.searchIndex.search(
            "Spring",
            languageID: english,
            count: 10,
            countryCode: "OL",
            administrativeArea: area
        )
        XCTAssertTrue(excludedByCountry.isEmpty)
    }

    func testAdministrativeAreaResolution() throws {
        let paths = try makeFixture(name: "administrative-areas")
        try GeocodingDatabaseBuilder(
            logger: Logger(label: "database-test"),
            options: DatabaseBuildOptions(memoryLimitBytes: 64 << 20, workers: 1),
            paths: paths
        ).build()

        let database = try GeocodingDatabase(url: paths.databaseFile)
        let resolver = try AdministrativeAreaResolver(database: database)
        let english = try XCTUnwrap(database.languageIDs["en"])
        let german = try XCTUnwrap(database.languageIDs["de"])
        let french = try XCTUnwrap(database.languageIDs["fr"])

        XCTAssertEqual(
            resolver.resolve("NR", languageID: english, countryCode: nil).admin1IDs,
            [110]
        )
        XCTAssertTrue(
            resolver.resolve("NR", languageID: english, countryCode: "OL").isEmpty
        )
        XCTAssertEqual(
            resolver.resolve("TL", languageID: english, countryCode: nil).admin1IDs,
            [210]
        )
        let countryCodeCollision = resolver.resolve(
            "TL",
            languageID: english,
            countryCode: "TL"
        )
        XCTAssertTrue(countryCodeCollision.admin1IDs.isEmpty)
        XCTAssertEqual(countryCodeCollision.countryCodes, ["TL"])
        XCTAssertEqual(
            resolver.resolve(
                "Shared Region",
                languageID: english,
                countryCode: nil
            ).admin1IDs,
            [110, 210]
        )
        XCTAssertEqual(
            resolver.resolve(
                "Shared Region",
                languageID: english,
                countryCode: "TL"
            ).admin1IDs,
            [110]
        )
        XCTAssertEqual(
            resolver.resolve(
                "Région commune",
                languageID: french,
                countryCode: nil
            ).admin1IDs,
            [110, 210]
        )
        XCTAssertEqual(
            resolver.resolve(
                "Republic of Testland",
                languageID: german,
                countryCode: nil
            ).countryCodes,
            ["TL"]
        )
        XCTAssertEqual(
            resolver.resolve("tl", languageID: english, countryCode: " tl ").countryCodes,
            ["TL"]
        )
    }

    func testAllCountryFeatureCodesAreResolved() throws {
        let featureCodes = ["PCLI", "PCLD", "PCLIX", "PCLS", "PCLF", "PCL"]
        let countryCodes = ["AA", "AB", "AC", "AD", "AE", "AF"]
        let rows = featureCodes.enumerated().map { offset, feature in
            row(
                offset + 1,
                "\(feature) Territory",
                Double(offset),
                Double(offset),
                feature,
                countryCodes[offset],
                "",
                0
            )
        }
        let paths = try makeFixture(
            name: "country-features",
            geonameRows: rows,
            alternateRows: featureCodes.enumerated().map { offset, feature in
                alternate(
                    offset + 1,
                    offset + 1,
                    "en",
                    "\(feature) Territory",
                    preferred: true
                )
            } + [alternate(7, 1, "post", "0000")]
        )
        try GeocodingDatabaseBuilder(
            logger: Logger(label: "database-test"),
            options: DatabaseBuildOptions(memoryLimitBytes: 64 << 20, workers: 1),
            paths: paths
        ).build()

        let database = try GeocodingDatabase(url: paths.databaseFile)
        let resolver = try AdministrativeAreaResolver(database: database)
        for (offset, feature) in featureCodes.enumerated() {
            let resolution = resolver.resolve(
                "\(feature) Territory",
                languageID: 0,
                countryCode: countryCodes[offset].lowercased()
            )
            XCTAssertEqual(resolution.countryCodes, [countryCodes[offset]])
            XCTAssertTrue(resolution.admin1IDs.isEmpty)
        }
    }

    func testRadixPrefixBoundariesAndExactMatching() throws {
        let paths = try makeFixture(name: "radix-boundaries")
        try GeocodingDatabaseBuilder(
            logger: Logger(label: "database-test"),
            options: DatabaseBuildOptions(memoryLimitBytes: 64 << 20, workers: 1),
            paths: paths
        ).build()

        let database = try GeocodingDatabase(url: paths.databaseFile)
        let english = try XCTUnwrap(database.languageIDs["en"])
        let german = try XCTUnwrap(database.languageIDs["de"])

        // Ends inside a compressed edge.
        XCTAssertEqual(
            database.searchIndex.search(
                "Spr",
                languageID: english,
                count: 10,
                countryCode: nil,
                administrativeArea: nil
            ).map(\.0),
            [120, 220, 121]
        )

        // Ends at an internal terminal and then below that terminal.
        XCTAssertEqual(
            database.searchIndex.search(
                "Springfield",
                languageID: english,
                count: 10,
                countryCode: nil,
                administrativeArea: nil
            ).map(\.0),
            [120, 220, 121]
        )
        XCTAssertEqual(
            database.searchIndex.search(
                "Springfield G",
                languageID: english,
                count: 10,
                countryCode: nil,
                administrativeArea: nil
            ).map(\.0),
            [121]
        )

        // A complete terminal leaf and a query extending beyond it.
        XCTAssertEqual(
            database.searchIndex.search(
                "Frühlingsfeld",
                languageID: german,
                count: 10,
                countryCode: nil,
                administrativeArea: nil
            ).map(\.0),
            [120]
        )
        XCTAssertTrue(
            database.searchIndex.search(
                "Frühlingsfelder",
                languageID: german,
                count: 10,
                countryCode: nil,
                administrativeArea: nil
            ).isEmpty
        )

        // One- and two-character queries retain exact-only behavior.
        XCTAssertTrue(
            database.searchIndex.search(
                "Sp",
                languageID: english,
                count: 10,
                countryCode: nil,
                administrativeArea: nil
            ).isEmpty
        )
    }

    func testBuildIsDeterministic() throws {
        let first = try makeFixture(name: "deterministic-a")
        let second = try makeFixture(name: "deterministic-b")
        let logger = Logger(label: "database-test")
        try GeocodingDatabaseBuilder(logger: logger, paths: first).build()
        try GeocodingDatabaseBuilder(logger: logger, paths: second).build()
        XCTAssertEqual(
            try Data(contentsOf: first.databaseFile),
            try Data(contentsOf: second.databaseFile)
        )
    }

    func testRejectsInvalidHeader() throws {
        let directory = try makeTemporaryDirectory(name: "invalid")
        let file = directory.appendingPathComponent("database-v2.bin")
        try Data(repeating: 0, count: DatabaseFileHeader.encodedSize).write(to: file)
        XCTAssertThrowsError(try GeocodingDatabase(url: file)) { error in
            guard case DatabaseFormatError.invalidMagic = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRejectsCorruptRadixEdge() throws {
        let paths = try makeFixture(name: "corrupt-edge")
        try GeocodingDatabaseBuilder(
            logger: Logger(label: "database-test"),
            options: DatabaseBuildOptions(memoryLimitBytes: 64 << 20, workers: 1),
            paths: paths
        ).build()

        let database = try GeocodingDatabase(url: paths.databaseFile)
        let descriptor = database.sectionDescriptor(.searchEdges)
        var contents = try Data(contentsOf: paths.databaseFile)
        contents.writeLittleEndian(
            UInt32.max,
            at: Int(descriptor.offset) + 4
        )
        let corruptFile = paths.databaseFile
            .deletingLastPathComponent()
            .appendingPathComponent("corrupt-database-v2.bin")
        try contents.write(to: corruptFile)

        XCTAssertThrowsError(try GeocodingDatabase(url: corruptFile)) { error in
            guard case DatabaseFormatError.invalidSection(.searchEdges, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testXXHash64KnownVectors() {
        let empty = XXHash64()
        XCTAssertEqual(empty.digest(), 0xef46_db37_51d8_e999)

        var hello = XXHash64()
        Array("hello".utf8).withUnsafeBytes {
            hello.update($0)
        }
        XCTAssertEqual(hello.digest(), 0x26c7_827d_889f_6da3)
    }

    func testPopulationRanking() {
        XCTAssertEqual(GeoNamesRecordRules.populationRank(0), 0)
        XCTAssertEqual(GeoNamesRecordRules.populationRank(10), 0.038468935, accuracy: 1e-7)
        XCTAssertEqual(GeoNamesRecordRules.populationRank(1_000), 0.03920805, accuracy: 1e-7)
        XCTAssertEqual(GeoNamesRecordRules.populationRank(10_000), 0.046580374, accuracy: 1e-7)
        XCTAssertEqual(GeoNamesRecordRules.populationRank(50_000), 0.09806819, accuracy: 1e-7)
        XCTAssertEqual(GeoNamesRecordRules.populationRank(100_000), 0.22813433, accuracy: 1e-7)
        XCTAssertEqual(GeoNamesRecordRules.populationRank(200_000), 0.6859223, accuracy: 1e-7)
        XCTAssertEqual(GeoNamesRecordRules.populationRank(500_000), 0.9988663, accuracy: 1e-7)
        XCTAssertEqual(GeoNamesRecordRules.populationRank(1_000_000), 1)
    }

    func testQualifierStopsAtNextComma() {
        let parsed = GeocodingapiController.parseSearchName(
            " Springfield, Shared Region, TL "
        )
        XCTAssertEqual(parsed.name, "Springfield")
        XCTAssertEqual(parsed.areaName, "Shared Region")
    }

    private func makeFixture(name: String) throws -> DatabaseBuildPaths {
        let geonameRows = [
            row(100, "Testland", 46.8, 8.2, "PCLI", "TL", "", 8_000_000),
            row(110, "Shared Region", 47.0, 8.4, "ADM1", "TL", "N", 2_000_000),
            row(120, "Springfield", 47.1, 8.5, "PPLA", "TL", "N", 500_000),
            row(121, "Springfield Gardens", 47.2, 8.6, "PPL", "TL", "N", 2_000),
            row(130, "Mountain", 47.3, 8.7, "MT", "TL", "N", 0),
            row(200, "Otherland", 40.0, 10.0, "PCLI", "OL", "", 6_000_000),
            row(210, "Shared Region", 40.0, 10.0, "ADM1", "OL", "S", 1_000_000),
            row(220, "Springfield", 40.1, 10.1, "PPL", "OL", "S", 20_000),
        ]
        let alternateRows = [
            alternate(1, 100, "en", "Testland", preferred: true),
            alternate(2, 110, "en", "North Region", preferred: true),
            alternate(3, 110, "de", "Nordregion", preferred: true),
            alternate(4, 110, "abbr", "NR", preferred: true),
            alternate(5, 120, "en", "Springfield", preferred: true),
            alternate(6, 120, "de", "Frühlingsfeld", preferred: true),
            alternate(7, 120, "", "Spring Field"),
            alternate(8, 120, "post", "1234"),
            alternate(9, 121, "en", "Springfield Gardens", preferred: true),
            alternate(10, 200, "en", "Otherland", preferred: true),
            alternate(11, 220, "en", "Springfield", preferred: true),
            alternate(12, 210, "en", "South Region", preferred: true),
            alternate(13, 110, "fr", "Région commune", preferred: true),
            alternate(14, 210, "fr", "Région commune", preferred: true),
            alternate(15, 120, "en", "Old Springfield", historic: true),
            alternate(16, 100, "", "Republic of Testland"),
            alternate(17, 210, "abbr", "TL", preferred: true),
        ]
        return try makeFixture(
            name: name,
            geonameRows: geonameRows,
            alternateRows: alternateRows
        )
    }

    private func makeFixture(
        name: String,
        geonameRows: [String],
        alternateRows: [String]
    ) throws -> DatabaseBuildPaths {
        let directory = try makeTemporaryDirectory(name: name)
        let geonames = directory.appendingPathComponent("allCountries.txt")
        let alternates = directory.appendingPathComponent("alternateNamesV2.txt")
        let database = directory.appendingPathComponent("database-v2.bin")
        try (geonameRows.joined(separator: "\n") + "\n")
            .data(using: .utf8)!
            .write(to: geonames)
        try (alternateRows.joined(separator: "\n") + "\n")
            .data(using: .utf8)!
            .write(to: alternates)

        return DatabaseBuildPaths(
            geonamesFile: geonames,
            alternateNamesFile: alternates,
            databaseFile: database
        )
    }

    private func makeTemporaryDirectory(name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "geocoding-database-\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func row(
        _ id: Int,
        _ name: String,
        _ latitude: Double,
        _ longitude: Double,
        _ feature: String,
        _ country: String,
        _ admin1: String,
        _ population: Int
    ) -> String {
        return [
            "\(id)", name, name, name, "\(latitude)", "\(longitude)", "A", feature,
            country, "", admin1, "", "", "", "\(population)", "", "400",
            "Europe/Zurich", "2026-01-01",
        ].joined(separator: "\t")
    }

    private func alternate(
        _ alternateID: Int,
        _ geonameID: Int,
        _ language: String,
        _ name: String,
        preferred: Bool = false,
        historic: Bool = false
    ) -> String {
        return [
            "\(alternateID)", "\(geonameID)", language, name,
            preferred ? "1" : "", "", "", historic ? "1" : "", "", "",
        ].joined(separator: "\t")
    }
}
