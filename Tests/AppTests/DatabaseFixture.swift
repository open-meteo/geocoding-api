import Foundation
import Logging

@testable import App

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
        population: UInt32 = 0,
        elevation: Int16? = 400,
        dem: Int16 = 400
    ) -> String {
        [
            String(id), name, name, "", "47", "8", "P", feature, country, "", admin, "", "", "",
            String(population), elevation.map { String($0) } ?? "", String(dem), "Europe/Zurich", "2026-01-01",
        ].joined(separator: "\t")
    }

    func build(force: Bool = false) throws -> GeocodingDatabase {
        try paths.build(force: force)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

extension DatabaseBuildPaths {
    func build(force: Bool = false) throws -> GeocodingDatabase {
        var logger = Logger(label: "fixture")
        logger.logLevel = .error
        try GeocodingDatabaseBuilder(
            logger: logger,
            options: .init(force: force),
            paths: self
        ).build()
        return try GeocodingDatabase(url: databaseFile)
    }
}
