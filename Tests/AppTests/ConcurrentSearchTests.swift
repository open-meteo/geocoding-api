import Testing

@testable import App

struct ConcurrentSearchTests {
    private struct Query: Sendable {
        let text: String
        let count: Int
        let country: String?
        let admin: Int32?
    }

    private struct Snapshot: Equatable, Sendable {
        let rows: [UInt32]
        let ids: [Int32]
        let scores: [Float]
        let names: [String]
    }

    private static func search(
        database: GeocodingDatabase,
        index: PackedRadixSearchIndex,
        language: UInt16,
        query: Query
    ) throws -> Snapshot {
        let hits = try index.search(
            query.text,
            languageID: language,
            count: query.count,
            countryCode: query.country,
            administrativeArea: query.admin.map { .init(admin1IDs: [$0]) }
        )
        return Snapshot(
            rows: hits.map(\.row),
            ids: hits.map(\.id),
            scores: hits.map(\.score),
            names: try database.responses(hits: hits, languageID: language).map(\.name)
        )
    }

    @Test
    func sharedDatabaseReadsKeepResultsConsistent() async throws {
        let fixture = try DatabaseFixture(count: 257)
        defer { fixture.remove() }
        let database = try await fixture.build()
        let language = try #require(database.languageIDs["en"])
        let index = database.searchIndex
        let locations = database.sectionBytes(.locations)
        let queries: [Query] = [
            .init(text: "Spring", count: 1, country: nil, admin: nil),
            .init(text: "Spring", count: 100, country: "AA", admin: nil),
            .init(text: "Spring Alias", count: 17, country: nil, admin: 4),
            .init(text: "Mün", count: 10, country: "BB", admin: 4),
            .init(text: "Spring", count: 16, country: "AA", admin: 4),
            .init(text: "Spring1", count: 10, country: nil, admin: nil),
            .init(text: "Sp", count: 10, country: nil, admin: nil),
            .init(text: "zzmissing", count: 10, country: nil, admin: nil),
        ]
        let expected = try queries.map {
            try Self.search(database: database, index: index, language: language, query: $0)
        }
        #expect(expected.contains { !$0.ids.isEmpty })
        #expect(expected.contains { $0.ids.isEmpty })

        try await withThrowingTaskGroup(of: Void.self) { group in
            for worker in 0..<16 {
                group.addTask {
                    // Capture the database, index, and range independently so all
                    // three Sendable conformances are checked at the task boundary.
                    for iteration in 0..<4 {
                        await Task.yield()
                        #expect(locations.readUInt32(at: 0) == 1)
                        for offset in queries.indices {
                            let position = (worker + iteration + offset) % queries.count
                            let actual = try Self.search(
                                database: database,
                                index: index,
                                language: language,
                                query: queries[position]
                            )
                            #expect(actual == expected[position])
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
    }
}
