import Foundation
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

extension DatabaseFixture {
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
                let boost: Float = name == normalized ? 1.5 : 1.5 / (1 + 0.1 * Float(name.count - normalized.count))
                return place.rank + boost
            }
            guard let score = scores.max() else { return nil }
            return (place.id, score)
        }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }.prefix(count).map { $0 }
    }
}

@Test(arguments: [63, 64, 65, 257, 2048])
func searchMatchesExhaustiveOracle(recordCount: Int) throws {
    let fixture = try DatabaseFixture(count: recordCount)
    defer { fixture.remove() }
    let database = try fixture.build()
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

@Test
func elevationRanksIndividualSummitsUsingExistingSourceFields() throws {
    let fixture = try DatabaseFixture(count: 0)
    defer { fixture.remove() }
    let cases: [(feature: String, elevation: Int16?, dem: Int16, score: Float)] = [
        ("PK", .max, 400, 2.0654845),
        ("PK", 6000, 400, 1.95),
        ("PK", 3000, 400, 1.86),
        ("MT", nil, 2000, 1.8),
        ("MT", 1000, 400, 1.7),
        ("PPL", 8000, 400, 1.6),
        ("PK", -10, 400, 1.5),
        ("MTS", 8000, 400, 1.5),
        ("PKS", 8000, 400, 1.5),
        ("MT", nil, -9999, 1.5),
    ]
    let rows = cases.enumerated().map { index, value in
        DatabaseFixture.row(
            id: Int32(100 + index), name: "Summit", feature: value.feature, country: "AA",
            elevation: value.elevation, dem: value.dem
        )
    }
    try (rows.joined(separator: "\n") + "\n").write(to: fixture.paths.geonamesFile, atomically: true, encoding: .utf8)
    try "".write(to: fixture.paths.alternateNamesFile, atomically: true, encoding: .utf8)
    let database = try fixture.build()
    let hits = try database.searchIndex.search(
        "Summit", languageID: UInt16.max, count: cases.count, countryCode: nil, administrativeArea: nil
    )
    #expect(hits.map(\.id) == cases.indices.map { Int32(100 + $0) })
    for (hit, expected) in zip(hits, cases) {
        #expect(abs(hit.score - expected.score) < 0.00001)
    }
}

@Test
func importantLongerNameCompetesWithExactMatches() throws {
    let fixture = try DatabaseFixture(count: 0)
    defer { fixture.remove() }
    let rows = [
        DatabaseFixture.row(id: 100, name: "Newcastle upon Tyne", feature: "PPL", country: "AA", population: 300_125),
        DatabaseFixture.row(id: 101, name: "Newcastle", feature: "PPL", country: "AA", population: 0),
        DatabaseFixture.row(id: 102, name: "Newcastle", feature: "PPL", country: "AA", population: 300_125),
    ]
    // No aliases: the longer name must compete through its prefix score alone.
    try (rows.joined(separator: "\n") + "\n").write(to: fixture.paths.geonamesFile, atomically: true, encoding: .utf8)
    try "".write(to: fixture.paths.alternateNamesFile, atomically: true, encoding: .utf8)
    let database = try fixture.build()
    for count in [1, 2, 3] {
        let hits = try database.searchIndex.search(
            "Newcastle", languageID: UInt16.max, count: count, countryCode: nil, administrativeArea: nil
        )
        // Exact wins at equal population; the important prefix beats the tiny exact match.
        #expect(hits.map(\.id) == Array([Int32(102), 100, 101].prefix(count)))
    }
}
