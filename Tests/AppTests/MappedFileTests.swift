import Foundation
import Testing

@testable import App

struct MappedFileTests {
    @Test
    func rangesRetainTheirMappingAfterUnlink() throws {
        let fixture = try DatabaseFixture(count: 0)
        defer { fixture.remove() }
        let url = fixture.directory.appendingPathComponent("mapped-bytes")
        try Data([255, 1, 2, 3, 4, 5, 6, 7, 8]).write(to: url)
        weak var owner: MappedFile?
        var retained: MappedBytes?
        do {
            let mapping = try MappedFile(url: url)
            owner = mapping
            retained = try mapping.bytes(offset: 1, length: 8)
            #expect(try mapping.bytes(offset: 9, length: 0).withSpan { $0.count } == 0)
            for (offset, length): (UInt64, UInt64) in [(10, 0), (8, 2), (.max, 1), (1, .max)] {
                #expect(throws: MappedFileError.self) {
                    try mapping.bytes(offset: offset, length: length)
                }
            }
        }
        try FileManager.default.removeItem(at: url)
        #expect(owner != nil)
        #expect(retained?.readUInt64(at: 0) == 0x0807_0605_0403_0201)
        #expect(retained?.withSpan { $0.extracting(1..<5).readUInt32(at: 0) } == 0x0504_0302)
        retained = nil
        #expect(owner == nil)
    }

    @Test
    func emptyMappingProvidesAnEmptyBorrow() throws {
        let fixture = try DatabaseFixture(count: 0)
        defer { fixture.remove() }
        let url = fixture.directory.appendingPathComponent("empty-mapping")
        try Data().write(to: url)
        let bytes = try MappedFile(url: url).bytes(offset: 0, length: 0)
        #expect(bytes.withSpan { $0.isEmpty })
    }

    @Test
    func retainedIndexAndSectionSurviveDatabaseReleaseAndReplacement() async throws {
        let fixture = try DatabaseFixture(count: 10)
        defer { fixture.remove() }
        var input = try String(contentsOf: fixture.paths.alternateNamesFile, encoding: .utf8)
        input += "9999\t100\ten\tBeforeReplacement\t1\t1\t\t\t\t\n"
        try input.write(to: fixture.paths.alternateNamesFile, atomically: true, encoding: .utf8)

        weak var originalDatabase: GeocodingDatabase?
        weak var originalMapping: MappedFile?
        var index: PackedRadixSearchIndex?
        var section: MappedBytes?
        let language: UInt16
        do {
            let database = try await fixture.build()
            originalDatabase = database
            originalMapping = database.mappedFile
            language = try #require(database.languageIDs["en"])
            index = database.searchIndex
            section = database.sectionBytes(.locations)
        }
        #expect(originalDatabase == nil)
        try input.replacingOccurrences(of: "BeforeReplacement", with: "AfterReplacement")
            .write(to: fixture.paths.alternateNamesFile, atomically: true, encoding: .utf8)
        let replacement = try await fixture.build(force: true)

        func ids(_ index: PackedRadixSearchIndex, _ query: String) throws -> [Int32] {
            try index.search(
                query, languageID: language, count: 10,
                countryCode: nil, administrativeArea: nil
            ).map(\.id)
        }
        #expect(try ids(index!, "BeforeReplacement") == [100])
        #expect(try ids(index!, "AfterReplacement").isEmpty)
        #expect(try ids(replacement.searchIndex, "AfterReplacement") == [100])
        #expect(section?.readUInt32(at: 0) == 1)
        index = nil
        #expect(originalMapping != nil)
        #expect(section?.withSpan { $0.readUInt32(at: 0) } == 1)
        section = nil
        #expect(originalMapping == nil)
    }
}
