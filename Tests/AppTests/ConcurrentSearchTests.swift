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
        let sources: [UInt16]
        let names: [String]
        let counters: [Int]
    }

    private static func counters(_ diagnostics: SearchDiagnostics) -> [Int] {
        [
            diagnostics.postingsExamined, diagnostics.namesExamined,
            diagnostics.treeNodesVisited, diagnostics.postingsRejectedByGeography,
            diagnostics.duplicateHits, diagnostics.heapInsertions,
            diagnostics.heapReplacements, diagnostics.heapUpdates,
        ]
    }

    private static func search(
        database: GeocodingDatabase,
        index: PackedRadixSearchIndex,
        language: UInt16,
        query: Query
    ) throws -> Snapshot {
        // Diagnostics belong to this invocation and never cross a task boundary.
        let diagnostics = SearchDiagnostics()
        let hits = try index.search(
            query.text,
            languageID: language,
            count: query.count,
            countryCode: query.country,
            administrativeArea: query.admin.map { .init(admin1IDs: [$0]) },
            diagnostics: diagnostics
        )
        let recorded = counters(diagnostics)
        let independent = SearchDiagnostics()
        let missing = try index.search(
            "zzmissing",
            languageID: language,
            count: 10,
            countryCode: nil,
            administrativeArea: nil,
            diagnostics: independent
        )
        #expect(missing.isEmpty)
        #expect(counters(independent) == Array(repeating: 0, count: 8))
        #expect(counters(diagnostics) == recorded)
        return Snapshot(
            rows: hits.map(\.row),
            ids: hits.map(\.id),
            scores: hits.map(\.score),
            sources: hits.map { $0.sources.rawValue },
            names: try database.responses(hits: hits, languageID: language).map(\.name),
            counters: recorded
        )
    }

    @Test
    func sharedDatabaseReadsKeepResultsAndDiagnosticsIndependent() async throws {
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
        #expect(expected.contains { $0.counters[0] > 0 })
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
