import Foundation
import Testing

@testable import App

@Test(arguments: [
    ("서울", "서울"), ("Tromsø", "tromso"), ("TROMSØ", "tromso"),
    ("Łódź", "lodz"), ("Ærø", "aero"), ("Straße", "strasse"),
    ("München", "munchen"), ("Αθήνα", "αθηνα"), ("Москва", "москва"),
    ("北京", "北京"), ("Berlin", "berlin"), ("", ""),
    ("Saint-Pétersbourg", "saint petersbourg"), ("Saint‑Domingue", "saint domingue"),
    ("Andorre-la-Vieille", "andorre la vieille"),
])
func normalizedSearchBytes(input: String, expected: String) {
    for spelling in [input, input.decomposedStringWithCanonicalMapping] {
        let normalized = SearchTextNormalizer.foldAndLowercase(spelling)
        #expect(Array(normalized.utf8) == Array(expected.utf8))
        #expect(Array(SearchTextNormalizer.foldAndLowercase(normalized).utf8) == Array(normalized.utf8))
    }
}

@Test(arguments: [false, true])
func normalizedNamesAndAliasesMatch(decomposedInput: Bool) throws {
    let fixture = try DatabaseFixture(count: 0)
    defer { fixture.remove() }
    func stored(_ value: String) -> String {
        decomposedInput ? value.decomposedStringWithCanonicalMapping : value
    }
    let names = ["서울", "Tromsø", "Saint-Pétersbourg", "Saint Domingue", "Andorre-la-Vieille"]
    var rows = [
        DatabaseFixture.row(id: 1, name: stored("대한민국"), feature: "PCLI", country: "KR"),
        DatabaseFixture.row(id: 3, name: stored("서울"), feature: "ADM1", country: "KR", admin: "R"),
    ]
    rows += names.enumerated().map {
        DatabaseFixture.row(id: Int32(100 + $0.offset), name: stored($0.element), feature: "PPL", country: "KR", admin: "R")
    }
    try rows.joined(separator: "\n").write(to: fixture.paths.geonamesFile, atomically: true, encoding: .utf8)
    let alternates = names.enumerated().map {
        "\($0.offset + 1)\t\($0.offset + 100)\tfr\t\(stored($0.element))\t1\t\t\t\t\t"
    }
    try alternates.joined(separator: "\n").write(to: fixture.paths.alternateNamesFile, atomically: true, encoding: .utf8)
    let database = try fixture.build()
    let french = try #require(database.languageIDs["fr"])
    let resolver = AdministrativeAreaResolver(database: database)
    for spelling in ["서울", "서울".decomposedStringWithCanonicalMapping] {
        let area = try resolver.resolve(spelling, languageID: french, countryCode: "KR")
        #expect(area.admin1IDs == [3])
        for (index, query) in [spelling, "Tromso", "Saint Pétersbourg", "Saint-Domingue", "Andorre la Vieille"].enumerated() {
            // Exercise canonical-only and localized indexes, with and without area filtering.
            for language in [UInt16.max, french] {
                for scoped in [false, true] {
                    let hits = try database.searchIndex.search(
                        query, languageID: language, count: 10, countryCode: nil,
                        administrativeArea: scoped ? area : nil
                    )
                    #expect(hits.contains { $0.id == Int32(index + 100) })
                }
            }
            let response = try #require(try database.response(id: Int32(index + 100), languageID: french))
            #expect(Array(response.name.utf8) == Array(stored(names[index]).utf8))
        }
    }
    let country = try resolver.resolve("대한민국".decomposedStringWithCanonicalMapping, languageID: french, countryCode: nil)
    #expect(country.countryCodes == ["KR"])
}
