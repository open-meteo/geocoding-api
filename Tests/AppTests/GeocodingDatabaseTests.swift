import Foundation
import Logging
import Testing

@testable import App

final class GeocodingDatabaseTests {
    private var temporaryDirectories = [URL]()

    deinit {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @Test
    func testBuildLoadSearchAndLocalizedResponse() async throws {
        let paths = try makeFixture(name: "primary")
        try await GeocodingDatabaseBuilder(
            logger: Logger(label: "database-test"),
            options: DatabaseBuildOptions(memoryLimitBytes: 64 << 20),
            paths: paths
        ).build()

        let database = try GeocodingDatabase(url: paths.databaseFile)
        #expect(database.recordCount == 8)
        #expect(database.header.maximumGeonameID == 220)
        #expect(database.header.sections.values.allSatisfy { $0.offset % 4096 == 0 })
        #expect(database.header.sections[.administrativeAliasRecords] != nil)
        #expect(database.header.sections[.administrativeAliasStrings] != nil)
        #expect(database.header.sections[.administrativeAliasCandidates] != nil)

        let english = try #require(database.languageIDs["en"])
        let german = try #require(database.languageIDs["de"])
        let response = try #require(try database.response(id: 120, languageID: german))
        #expect(response.name == "Frühlingsfeld")
        #expect(response.country == "Testland")
        #expect(response.admin1 == "Nordregion")
        #expect(response.postcodes == ["1234"])
        #expect(response.timezone == "Europe/Zurich")

        let exact = try database.searchIndex.search(
            "Springfield",
            languageID: english,
            count: 10,
            countryCode: nil,
            administrativeArea: nil
        )
        #expect(exact.map(\.id) == [120, 220, 121])
        #expect(exact[0].score > exact[1].score)

        let prefix = try database.searchIndex.search(
            "Spring",
            languageID: english,
            count: 10,
            countryCode: "TL",
            administrativeArea: nil
        )
        #expect(prefix.map(\.id) == [120, 121])

        let germanSearch = try database.searchIndex.search(
            "Fruhl",
            languageID: german,
            count: 10,
            countryCode: nil,
            administrativeArea: nil
        )
        #expect(germanSearch.map(\.id) == [120])

        let postcode = try database.searchIndex.search(
            "1234",
            languageID: english,
            count: 10,
            countryCode: nil,
            administrativeArea: nil
        )
        #expect(postcode.map(\.id) == [120])

        let historic = try database.searchIndex.search(
            "Old Springfield",
            languageID: english,
            count: 10,
            countryCode: nil,
            administrativeArea: nil
        )
        #expect(historic.isEmpty)

        let lookup = AdministrativeAreaResolver(database: database)
        let area = try lookup.resolve("NR", languageID: english, countryCode: "TL")
        let filtered = try database.searchIndex.search(
            "Spring",
            languageID: english,
            count: 10,
            countryCode: nil,
            administrativeArea: area
        )
        #expect(filtered.map(\.id) == [120, 121])

        let filteredByCountryAndArea = try database.searchIndex.search(
            "Spring",
            languageID: english,
            count: 10,
            countryCode: "TL",
            administrativeArea: area
        )
        #expect(filteredByCountryAndArea.map(\.id) == [120, 121])

        let excludedByCountry = try database.searchIndex.search(
            "Spring",
            languageID: english,
            count: 10,
            countryCode: "OL",
            administrativeArea: area
        )
        #expect(excludedByCountry.isEmpty)
    }

    @Test
    func testAdministrativeAreaResolution() async throws {
        let paths = try makeFixture(name: "administrative-areas")
        try await GeocodingDatabaseBuilder(
            logger: Logger(label: "database-test"),
            options: DatabaseBuildOptions(memoryLimitBytes: 64 << 20),
            paths: paths
        ).build()

        let database = try GeocodingDatabase(url: paths.databaseFile)
        let resolver = AdministrativeAreaResolver(database: database)
        let english = try #require(database.languageIDs["en"])
        let german = try #require(database.languageIDs["de"])
        let french = try #require(database.languageIDs["fr"])

        #expect(try resolver.resolve("NR", languageID: english, countryCode: nil).admin1IDs == [110])
        #expect(try resolver.resolve("NR", languageID: english, countryCode: "OL").isEmpty)
        #expect(try resolver.resolve("TL", languageID: english, countryCode: nil).admin1IDs == [210])
        let countryCodeCollision = try resolver.resolve(
            "TL",
            languageID: english,
            countryCode: "TL"
        )
        #expect(countryCodeCollision.admin1IDs.isEmpty)
        #expect(countryCodeCollision.countryCodes == ["TL"])
        #expect(
            try resolver.resolve(
                "Shared Region",
                languageID: english,
                countryCode: nil
            ).admin1IDs == [110, 210]
        )
        #expect(
            try resolver.resolve(
                "Shared Region",
                languageID: english,
                countryCode: "TL"
            ).admin1IDs == [110]
        )
        #expect(
            try resolver.resolve(
                "Région commune",
                languageID: french,
                countryCode: nil
            ).admin1IDs == [110, 210]
        )
        #expect(
            try resolver.resolve(
                "Republic of Testland",
                languageID: german,
                countryCode: nil
            ).countryCodes == ["TL"]
        )
        #expect(try resolver.resolve("tl", languageID: english, countryCode: " tl ").countryCodes == ["TL"])
    }

    @Test
    func testAllCountryFeatureCodesAreResolved() async throws {
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
        try await GeocodingDatabaseBuilder(
            logger: Logger(label: "database-test"),
            options: DatabaseBuildOptions(memoryLimitBytes: 64 << 20),
            paths: paths
        ).build()

        let database = try GeocodingDatabase(url: paths.databaseFile)
        let resolver = AdministrativeAreaResolver(database: database)
        for (offset, feature) in featureCodes.enumerated() {
            let resolution = try resolver.resolve(
                "\(feature) Territory",
                languageID: 0,
                countryCode: countryCodes[offset].lowercased()
            )
            #expect(resolution.countryCodes == [countryCodes[offset]])
            #expect(resolution.admin1IDs.isEmpty)
        }
    }

    @Test
    func testRadixPrefixBoundariesAndExactMatching() async throws {
        let paths = try makeFixture(name: "radix-boundaries")
        try await GeocodingDatabaseBuilder(
            logger: Logger(label: "database-test"),
            options: DatabaseBuildOptions(memoryLimitBytes: 64 << 20),
            paths: paths
        ).build()

        let database = try GeocodingDatabase(url: paths.databaseFile)
        let english = try #require(database.languageIDs["en"])
        let german = try #require(database.languageIDs["de"])

        // Ends inside a compressed edge.
        #expect(
            try database.searchIndex.search(
                "Spr",
                languageID: english,
                count: 10,
                countryCode: nil,
                administrativeArea: nil
            ).map(\.id) == [120, 220, 121]
        )

        // Ends at an internal terminal and then below that terminal.
        #expect(
            try database.searchIndex.search(
                "Springfield",
                languageID: english,
                count: 10,
                countryCode: nil,
                administrativeArea: nil
            ).map(\.id) == [120, 220, 121]
        )
        #expect(
            try database.searchIndex.search(
                "Springfield G",
                languageID: english,
                count: 10,
                countryCode: nil,
                administrativeArea: nil
            ).map(\.id) == [121]
        )

        // A complete terminal leaf and a query extending beyond it.
        #expect(
            try database.searchIndex.search(
                "Frühlingsfeld",
                languageID: german,
                count: 10,
                countryCode: nil,
                administrativeArea: nil
            ).map(\.id) == [120]
        )
        #expect(
            try database.searchIndex.search(
                "Frühlingsfelder",
                languageID: german,
                count: 10,
                countryCode: nil,
                administrativeArea: nil
            ).isEmpty
        )

        // One- and two-character queries retain exact-only behavior.
        #expect(
            try database.searchIndex.search(
                "Sp",
                languageID: english,
                count: 10,
                countryCode: nil,
                administrativeArea: nil
            ).isEmpty
        )
    }

    @Test
    func testBuildIsDeterministic() async throws {
        let first = try makeFixture(name: "deterministic-a")
        let second = try makeFixture(name: "deterministic-b")
        let logger = Logger(label: "database-test")
        try await GeocodingDatabaseBuilder(logger: logger, paths: first).build()
        try await GeocodingDatabaseBuilder(logger: logger, paths: second).build()
        #expect(try Data(contentsOf: first.databaseFile) == Data(contentsOf: second.databaseFile))
    }

    @Test
    func testRejectsInvalidHeader() throws {
        let directory = try makeTemporaryDirectory(name: "invalid")
        let file = directory.appendingPathComponent("database-v2.bin")
        try Data(repeating: 0, count: DatabaseFileHeader.encodedSize).write(to: file)
        #expect {
            try GeocodingDatabase(url: file)
        } throws: { error in
            guard case DatabaseFormatError.invalidMagic = error else {
                return false
            }
            return true
        }
    }

    @Test
    func testRejectsCorruptRadixEdge() async throws {
        let paths = try makeFixture(name: "corrupt-edge")
        try await GeocodingDatabaseBuilder(
            logger: Logger(label: "database-test"),
            options: DatabaseBuildOptions(memoryLimitBytes: 64 << 20),
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

        #expect {
            try GeocodingDatabase(url: corruptFile)
        } throws: { error in
            guard case DatabaseFormatError.invalidSection(.searchEdges, _) = error else {
                return false
            }
            return true
        }
    }

    @Test
    func testRejectsInvalidPostingAndAdministrativeAliasRanges() async throws {
        let paths = try makeFixture(name: "corrupt-structural-ranges")
        try await GeocodingDatabaseBuilder(
            logger: Logger(label: "database-test"),
            options: DatabaseBuildOptions(memoryLimitBytes: 64 << 20),
            paths: paths
        ).build()

        let database = try GeocodingDatabase(url: paths.databaseFile)
        let original = try Data(contentsOf: paths.databaseFile)

        var corruptPosting = original
        let postingDescriptor = database.sectionDescriptor(.searchPostings)
        corruptPosting.writeLittleEndian(
            UInt32.max,
            at: Int(postingDescriptor.offset)
        )
        let postingFile = paths.databaseFile
            .deletingLastPathComponent()
            .appendingPathComponent("corrupt-posting.bin")
        try corruptPosting.write(to: postingFile)
        #expect {
            try GeocodingDatabase(url: postingFile)
        } throws: { error in
            guard case DatabaseFormatError.invalidSection(.searchPostings, _) = error else {
                return false
            }
            return true
        }

        var corruptAlias = original
        let aliasDescriptor = database.sectionDescriptor(.administrativeAliasRecords)
        corruptAlias.writeLittleEndian(
            UInt32.max,
            at: Int(aliasDescriptor.offset) + 8
        )
        let aliasFile = paths.databaseFile
            .deletingLastPathComponent()
            .appendingPathComponent("corrupt-alias.bin")
        try corruptAlias.write(to: aliasFile)
        #expect {
            try GeocodingDatabase(url: aliasFile)
        } throws: { error in
            guard
                case DatabaseFormatError.invalidSection(
                    .administrativeAliasRecords,
                    _
                ) = error
            else {
                return false
            }
            return true
        }

        var missingAliasSection = original
        missingAliasSection.writeLittleEndian(
            UInt32(database.header.sections.count - 1),
            at: 48
        )
        let missingAliasFile = paths.databaseFile
            .deletingLastPathComponent()
            .appendingPathComponent("missing-alias-section.bin")
        try missingAliasSection.write(to: missingAliasFile)
        #expect {
            try GeocodingDatabase(url: missingAliasFile)
        } throws: { error in
            guard
                case DatabaseFormatError.missingSection(
                    .administrativeAliasCandidates
                ) = error
            else {
                return false
            }
            return true
        }
    }

    @Test
    func testXXHash64KnownVectors() {
        let empty = XXHash64()
        #expect(empty.digest() == 0xef46_db37_51d8_e999)

        var hello = XXHash64()
        Array("hello".utf8).withUnsafeBytes {
            hello.update($0)
        }
        #expect(hello.digest() == 0x26c7_827d_889f_6da3)
    }

    @Test
    func testPopulationRanking() {
        #expect(GeoNamesRecordRules.populationRank(0) == 0)
        #expect(abs(GeoNamesRecordRules.populationRank(10) - 0.038468935) <= 1e-7)
        #expect(abs(GeoNamesRecordRules.populationRank(1_000) - 0.03920805) <= 1e-7)
        #expect(abs(GeoNamesRecordRules.populationRank(10_000) - 0.046580374) <= 1e-7)
        #expect(abs(GeoNamesRecordRules.populationRank(50_000) - 0.09806819) <= 1e-7)
        #expect(abs(GeoNamesRecordRules.populationRank(100_000) - 0.22813433) <= 1e-7)
        #expect(abs(GeoNamesRecordRules.populationRank(200_000) - 0.6859223) <= 1e-7)
        #expect(abs(GeoNamesRecordRules.populationRank(500_000) - 0.9988663) <= 1e-7)
        #expect(GeoNamesRecordRules.populationRank(1_000_000) == 1)
    }

    @Test
    func testQualifierStopsAtNextComma() {
        let parsed = GeocodingapiController.parseSearchName(
            " Springfield, Shared Region, TL "
        )
        #expect(parsed.name == "Springfield")
        #expect(parsed.areaName == "Shared Region")
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
