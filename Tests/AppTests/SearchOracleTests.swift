import Foundation
import Logging
import Testing

@testable import App

/// The reference operates on source records, never index metadata or traversal helpers.
struct OraclePlace {
    let id: Int32
    let name: String
    let alternate: String
    let country: String
    let admin: Int32
    let population: UInt32

    var rank: Float {
        let populationScore: Float =
            population == 0
            ? 0
            : 1 / (1 + 25 * expf(-Float(population) / 50_000))
        return populationScore + 0.1  // PPL, no postal-code boost.
    }
}

struct DatabaseFixture {
    let directory: URL
    let paths: DatabaseBuildPaths
    let places: [OraclePlace]

    init(count: Int, seed: UInt64 = 17) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        paths = .init(
            geonamesFile: directory.appendingPathComponent("allCountries.txt"),
            alternateNamesFile: directory.appendingPathComponent("alternateNamesV2.txt"),
            databaseFile: directory.appendingPathComponent("database.bin")
        )
        var state = seed
        var places = [OraclePlace]()
        let lengths = [3, 4, 7, 8, 11, 12, 15, 16, 23, 24, 31, 32, 47, 48, 63, 64, 95, 96, 127, 128, 255, 256]
        for index in 0..<count {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let stem = index % 11 == 0 ? "München" : "Spring"
            let suffix = String(index % 701)
            let length = lengths[index % lengths.count]
            let name = stem + String(repeating: "a", count: max(0, length - stem.count - suffix.count)) + suffix
            places.append(
                .init(
                    id: Int32(index + 100),
                    name: name,
                    alternate: index % 3 == 0 ? name : "Spring Alias \(index % 137)",
                    country: index % 9 == 0 ? "BB" : "AA",
                    admin: index % 9 == 0 ? 4 : 3,
                    population: UInt32(state % 7) * 100_000
                )
            )
        }
        self.places = places
        var rows = [
            Self.row(id: 1, name: "Country A", feature: "PCLI", country: "AA"),
            Self.row(id: 2, name: "Country B", feature: "PCLI", country: "BB"),
            Self.row(id: 3, name: "Region A", feature: "ADM1", country: "AA", admin: "R"),
            Self.row(id: 4, name: "Region B", feature: "ADM1", country: "BB", admin: "R"),
        ]
        rows += places.map {
            Self.row(
                id: $0.id,
                name: $0.name,
                feature: "PPL",
                country: $0.country,
                admin: "R",
                population: $0.population
            )
        }
        // Countries have the optional postcode; search places deliberately do not.
        var alternates = ["1\t1\ten\tCountry A\t1\t\t\t\t\t", "2\t1\tpost\t0000\t\t\t\t\t\t"]
        alternates += places.enumerated().map {
            "\($0.offset + 3)\t\($0.element.id)\ten\t\($0.element.alternate)\t1\t\t\t\t\t"
        }
        try (rows.joined(separator: "\n") + "\n").write(to: paths.geonamesFile, atomically: true, encoding: .utf8)
        try (alternates.joined(separator: "\n") + "\n").write(
            to: paths.alternateNamesFile,
            atomically: true,
            encoding: .utf8
        )
    }

    static func row(
        id: Int32,
        name: String,
        feature: String,
        country: String,
        admin: String = "",
        population: UInt32 = 0
    ) -> String {
        [
            String(id), name, name, "", "47", "8", "P", feature, country, "", admin, "", "", "",
            String(population), "400", "400", "Europe/Zurich", "2026-01-01",
        ].joined(separator: "\t")
    }

    func build(budget: Int = 64 << 20, force: Bool = false) async throws -> GeocodingDatabase {
        var logger = Logger(label: "fixture")
        logger.logLevel = .error
        try await GeocodingDatabaseBuilder(
            logger: logger,
            options: .init(memoryLimitBytes: budget, force: force),
            paths: paths
        ).build()
        return try GeocodingDatabase(url: paths.databaseFile)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    func exhaustive(_ query: String, country: String?, admin: Int32?, count: Int) -> [(Int32, Float)] {
        func normalize(_ value: String) -> String {
            value.folding(options: .diacriticInsensitive, locale: nil).lowercased()
        }
        let normalized = normalize(query)
        return places.compactMap { place -> (Int32, Float)? in
            guard country == nil || country == place.country,
                admin == nil || admin == place.admin
            else { return nil }
            let scores = [place.name, place.alternate].compactMap { candidate -> Float? in
                let name = normalize(candidate)
                guard query.count <= 2 ? name == normalized : name.hasPrefix(normalized) else { return nil }
                let boost: Float = name == normalized ? 1.5 : 1.5 / Float(name.count - normalized.count + 1)
                return place.rank + boost
            }
            guard let score = scores.max() else { return nil }
            return (place.id, score)
        }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }.prefix(count).map { $0 }
    }
}

@Test(arguments: [63, 64, 65, 257, 2048])
func searchMatchesExhaustiveOracle(recordCount: Int) async throws {
    let fixture = try DatabaseFixture(count: recordCount)
    defer { fixture.remove() }
    let database = try await fixture.build()
    let language = try #require(database.languageIDs["en"])
    for query in ["Sp", "Spr", "Spring", "Spring Alias", "Spring0", "Springa", "Mün", "zzmissing"] {
        for country in [nil, "AA", "BB"] as [String?] {
            for admin in [nil, 3, 4] as [Int32?] {
                for count in [1, 10, 16, 17, 100] {
                    let expected = fixture.exhaustive(query, country: country, admin: admin, count: count)
                    let actual = try database.searchIndex.search(
                        query,
                        languageID: language,
                        count: count,
                        countryCode: country,
                        administrativeArea: admin.map { .init(admin1IDs: [$0]) }
                    )
                    #expect(
                        actual.map(\.id) == expected.map(\.0),
                        "\(query), \(String(describing: country)), \(String(describing: admin)), \(count)"
                    )
                    #expect(actual.map(\.score) == expected.map(\.1))
                }
            }
        }
    }
}
