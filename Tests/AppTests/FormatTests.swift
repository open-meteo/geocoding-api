import Foundation
import Logging
import Testing

@testable import App

@Suite(.serialized)
struct FormatTests {
    @Test
    func signedASCIIIntegersPreserveTheirSign() {
        for value: Int32 in [0, -42, -233, -1_234_567, 42, 1234, 1_234_567, .min, .max] {
            Array(String(value).utf8).withUnsafeBufferPointer { bytes in
                let parsed = Span(_unsafeElements: bytes).signedInteger
                #expect(parsed == value)
            }
        }
        for value: Int16 in [0, -42, -233, 42, 1234, .min, .max] {
            Array(String(value).utf8).withUnsafeBufferPointer { bytes in
                let parsed = Span(_unsafeElements: bytes).signedInt16
                #expect(parsed == value)
            }
        }
    }

    @Test
    func alternatePreferenceAndSourceOrderArePreserved() async throws {
        let fixture = try DatabaseFixture(count: 4)
        defer { fixture.remove() }
        var input = try String(contentsOf: fixture.paths.alternateNamesFile, encoding: .utf8)
        input += "9999\t100\ten\tChosen\t1\t1\t\t\t\t\n"
        input += "10000\t100\ten\tLater\t1\t1\t\t\t\t\n"
        // Rejected names cross reader refills, including a record larger than its buffer.
        for index in 0..<300 {
            let name = String(repeating: "x", count: index == 150 ? 70_000 : 300)
            input += "\(10001 + index)\t100\ten\t\(name)\t1\t\t\t\t\t\n"
        }
        input += "10301\t100\tfr\tChoisi\t1\t1\t\t\t\t\n"
        input += "10302\t100\tpost\t2000\t\t\t\t\t\t\n"
        input += "10303\t100\tpost\t1000\t\t\t\t\t\t\n"
        input += "10304\t100\tpost\t2000\t\t\t\t\t\t\n"
        try input.write(to: fixture.paths.alternateNamesFile, atomically: true, encoding: .utf8)
        let database = try await fixture.build()
        #expect(try database.response(id: 100, languageID: 0)?.name == "Chosen")
        let french = try #require(database.languageIDs["fr"])
        #expect(try database.response(id: 100, languageID: french)?.name == "Choisi")
        #expect(try database.response(id: 100, languageID: 0)?.postcodes == ["2000", "1000", "2000"])
        #expect(
            try database.searchIndex.search(
                "Later",
                languageID: 0,
                count: 10,
                countryCode: nil,
                administrativeArea: nil
            ).isEmpty
        )
    }

    @Test
    func sectionHashesDoNotDependOnWriterBufferSize() {
        let data = (0..<131_073).map { UInt8(truncatingIfNeeded: $0 &* 17) }
        var whole = XXHash64()
        data.withUnsafeBytes { whole.update($0) }
        for size in [1, 7, 31, 32, 33, 65_536] {
            var streaming = XXHash64()
            data.withUnsafeBytes { bytes in
                for start in stride(from: 0, to: bytes.count, by: size) {
                    streaming.update(UnsafeRawBufferPointer(rebasing: bytes[start..<min(bytes.count, start + size)]))
                }
            }
            #expect(streaming.digest() == whole.digest())
        }
    }

    @Test
    func hashTailBoundariesAndCopies() {
        let data = (0..<97).map { UInt8(truncatingIfNeeded: $0 &* 17) }
        data.withUnsafeBufferPointer { buffer in
            let bytes = Span(_unsafeElements: buffer)
            for length in 0...96 {
                var whole = XXHash64()
                whole.update(bytes.extracting(0..<length))
                for split in 0...length {
                    var prefix = XXHash64()
                    prefix.update(bytes.extracting(0..<split))
                    let prefixDigest = prefix.digest()
                    var copy = prefix
                    copy.update(bytes.extracting(split..<length))
                    copy.update(bytes.extracting(0..<0))
                    #expect(copy.digest() == whole.digest())
                    #expect(prefix.digest() == prefixDigest)
                    prefix.update(bytes.extracting(split..<length + 1))
                    var extended = XXHash64()
                    extended.update(bytes.extracting(0..<length + 1))
                    #expect(prefix.digest() == extended.digest())
                    #expect(copy.digest() == whole.digest())
                }
            }
        }
    }

    @Test
    func structuralOpenChecksQueryTouchedRanges() async throws {
        let fixture = try DatabaseFixture(count: 65)
        defer { fixture.remove() }
        let database = try await fixture.build()
        let original = try Data(contentsOf: fixture.paths.databaseFile)
        let output = fixture.directory.appendingPathComponent("query-corrupt.bin")
        for kind in [DatabaseSectionKind.searchNameMetadata, .searchEdges, .administrativeAliasRecords] {
            let section = database.sectionDescriptor(kind)
            var corrupted = original
            for index in 0..<Int(section.count) {
                let record = Int(section.offset) + index * Int(section.stride)
                corrupted.writeLittleEndian(UInt32.max, at: record + (kind == .searchNameMetadata ? 0 : 4))
            }
            try corrupted.write(to: output)
            let fast = try GeocodingDatabase(url: output, verification: .structure)
            if kind == .administrativeAliasRecords {
                #expect(throws: (any Error).self) {
                    try AdministrativeAreaResolver(database: fast).resolve("Region A", languageID: 0, countryCode: nil)
                }
            } else {
                #expect(throws: (any Error).self) {
                    try fast.searchIndex.search(
                        "Spring",
                        languageID: 0,
                        count: 10,
                        countryCode: nil,
                        administrativeArea: nil
                    )
                }
            }
        }
        let absent = fixture.directory.appendingPathComponent("missing.bin")
        #expect(throws: (any Error).self) {
            try GeocodingDatabase.open(logger: Logger(label: "missing-test"), url: absent)
        }
        #expect(!FileManager.default.fileExists(atPath: absent.path))
    }

    @Test(arguments: [false, true])
    func emptySections(noAlternates: Bool) async throws {
        let fixture = try DatabaseFixture(count: 4)
        defer { fixture.remove() }
        let input = try String(contentsOf: fixture.paths.alternateNamesFile, encoding: .utf8)
        let replacement =
            noAlternates
            ? "" : input.split(separator: "\n").filter { !$0.contains("\tpost\t") }.joined(separator: "\n") + "\n"
        try replacement.write(to: fixture.paths.alternateNamesFile, atomically: true, encoding: .utf8)
        let database = try await fixture.build()
        #expect(try database.response(id: 100, languageID: 0)?.postcodes == [])
        #expect(database.header.sections[.postcodeOffsets]?.length == 0)
        if noAlternates { #expect(database.header.sections[.alternateRecords]?.length == 0) }
    }

    @Test
    func deduplicatedResultsAndRecordLayout() async throws {
        let fixture = try DatabaseFixture(count: 65)
        defer { fixture.remove() }
        let database = try await fixture.build()
        let header = try Data(contentsOf: fixture.paths.databaseFile).prefix(64)
        #expect(Array(header.prefix(8)) == Array("GEOCDV1\0".utf8))
        header.withUnsafeBytes { bytes in
            #expect(bytes.readUInt32(at: 8) == 1)
            #expect(bytes.readUInt32(at: 52) == 1)
            #expect(bytes.readUInt32(at: 56) == 1)
        }
        #expect(DatabaseBuildPaths.default.databaseFile.lastPathComponent == "database-v1.bin")
        let language = try #require(database.languageIDs["en"])
        let place = fixture.places[0]
        let hits = try database.searchIndex.search(
            place.name,
            languageID: language,
            count: 100,
            countryCode: nil,
            administrativeArea: nil
        )
        let hit = try #require(hits.first { $0.id == place.id })
        #expect(hits.filter { $0.id == place.id }.count == 1)
        #expect(database.header.sections[.locations]?.stride == 64)
        #expect(database.header.sections[.searchPostings]?.stride == 14)
        let response = try #require(database.responses(hits: [hit], languageID: language).first)
        #expect(response.id == place.id)
        #expect(response.population == place.population)
        #expect(response.latitude == 47 && response.longitude == 8)
        #expect(response.elevation == 400)
        #expect(response.countryCode == place.country)
        #expect(response.admin1ID == place.admin)
    }

    @Test
    func publicationPreservesOldMappingAndRejectsUnforcedReplacement() async throws {
        let fixture = try DatabaseFixture(count: 10)
        defer { fixture.remove() }
        let old = try await fixture.build()
        let original = try Data(contentsOf: fixture.paths.databaseFile)
        await #expect(throws: (any Error).self) { _ = try await fixture.build() }
        #expect(try Data(contentsOf: fixture.paths.databaseFile) == original)
        let names = try String(contentsOf: fixture.paths.alternateNamesFile, encoding: .utf8)
        try names.replacingOccurrences(of: "Country A", with: "Updated Country")
            .write(to: fixture.paths.alternateNamesFile, atomically: true, encoding: .utf8)
        let replacement = try await fixture.build(force: true)
        #expect(try old.response(id: 1, languageID: 0)?.name == "Country A")
        #expect(try replacement.response(id: 1, languageID: 0)?.name == "Updated Country")
        try "invalid input\n".write(to: fixture.paths.geonamesFile, atomically: true, encoding: .utf8)
        let published = try Data(contentsOf: fixture.paths.databaseFile)
        await #expect(throws: (any Error).self) { _ = try await fixture.build(force: true) }
        #expect(try Data(contentsOf: fixture.paths.databaseFile) == published)
    }

    @Test
    func deterministicAcrossBudgetsAndRejectsSmallBudget() async throws {
        let fixture = try DatabaseFixture(count: 257)
        defer { fixture.remove() }
        _ = try await fixture.build(budget: 64 << 20)
        let first = try Data(contentsOf: fixture.paths.databaseFile)
        _ = try await fixture.build(budget: 128 << 20, force: true)
        #expect(try Data(contentsOf: fixture.paths.databaseFile) == first)
        await #expect(throws: (any Error).self) { _ = try await fixture.build(budget: 1 << 20, force: true) }
        #expect(try Data(contentsOf: fixture.paths.databaseFile) == first)
    }

    @Test
    func checksumAndSemanticRankVerification() async throws {
        let fixture = try DatabaseFixture(count: 257)
        defer { fixture.remove() }
        let database = try await fixture.build()
        let original = try Data(contentsOf: fixture.paths.databaseFile)
        let section = database.sectionDescriptor(.searchGlobalTrees)
        var corrupted = original
        corrupted[Int(section.offset) + PackedRadixIndexLayout.treeNodeStride] ^= 1
        let output = fixture.directory.appendingPathComponent("corrupt.bin")
        try corrupted.write(to: output)
        #expect(throws: (any Error).self) { try GeocodingDatabase(url: output) }
        // Fast open intentionally doesn't claim to authenticate every payload byte.
        _ = try GeocodingDatabase(url: output, verification: .structure)
        var hasher = XXHash64()
        corrupted.withUnsafeBytes { bytes in
            hasher.update(
                UnsafeRawBufferPointer(rebasing: bytes[Int(section.offset)..<Int(section.offset + section.length)])
            )
        }
        for index in 0..<database.header.sections.count {
            let offset = DatabaseFileHeader.directoryOffset + index * DatabaseSectionDescriptor.encodedSize
            let kind = corrupted.withUnsafeBytes { $0.readUInt32(at: offset) }
            if kind == DatabaseSectionKind.searchGlobalTrees.rawValue {
                corrupted.writeLittleEndian(hasher.digest(), at: offset + 40)
            }
        }
        try corrupted.write(to: output)
        #expect(throws: (any Error).self) { try GeocodingDatabase(url: output) }
        var incompatible = original
        incompatible.writeLittleEndian(UInt32.max, at: 52)
        try incompatible.write(to: output)
        #expect(throws: (any Error).self) { try GeocodingDatabase(url: output, verification: .structure) }
        try original.prefix(original.count - 1).write(to: output)
        #expect(throws: (any Error).self) { try GeocodingDatabase(url: output) }
    }

    @Test
    func boundedRunsWithMultipleMergePasses() throws {
        let fixture = try DatabaseFixture(count: 0)
        defer { fixture.remove() }
        let input = fixture.directory.appendingPathComponent("sort-input")
        let writer = try BufferedBinaryWriter(url: input)
        for value in stride(from: 600_000, through: 0, by: -1) { try writer.write(UInt32(value)) }
        _ = try writer.close()
        let sorted = try ExternalSort.sort(
            inputs: [input],
            workspace: fixture.directory,
            label: "test",
            headerSize: 4,
            memoryBytes: 8 << 20,
            fanIn: 2
        ) {
            $0.readUInt32(at: 0) < $1.readUInt32(at: 0)
        }
        let reader = try BinaryRecordReader(url: sorted, headerSize: 4)
        var expected: UInt32 = 0
        while let record = try reader.next() {
            let actual = record.withUnsafeBytes { $0.readUInt32(at: 0) }
            guard actual == expected else { Issue.record("external merge out of order"); return }
            expected += 1
        }
        #expect(expected == 600_001)
    }

    @Test
    func borrowedRecordsAcrossRefillsAndOwnedHeads() throws {
        let fixture = try DatabaseFixture(count: 0)
        defer { fixture.remove() }
        let input = fixture.directory.appendingPathComponent("variable-records")
        let writer = try BufferedBinaryWriter(url: input)
        // The third header straddles the reader's 64 KiB refill boundary.
        let lengths = [0, 65_519, 0, 65_536, 131_073]
        for (index, length) in lengths.enumerated() {
            try writer.write(UInt32(index))
            try writer.write(UInt32(length))
            try writer.write(Data(repeating: UInt8(index), count: length))
        }
        _ = try writer.close()
        let reader = try BinaryRecordReader(url: input, headerSize: 8, lengthOffset: 4)
        let first = try reader.withNextRecord { $0.readUInt32(at: 0) }
        #expect(first == 0)
        let owned = try #require(try reader.next())
        for index in 2..<lengths.count {
            let observed = try reader.withNextRecord { bytes in
                #expect(bytes.count == 8 + lengths[index])
                #expect(bytes.readUInt32(at: 0) == UInt32(index))
                #expect(bytes.withUnsafeBufferPointer { $0.dropFirst(8).allSatisfy { $0 == UInt8(index) } })
                return true
            }
            #expect(observed == true)
        }
        #expect(try reader.next() == nil)
        #expect(owned.count == 65_527)
        #expect(owned.dropFirst(8).allSatisfy { $0 == 1 })

        for data in [Data([0, 1, 2]), owned.dropLast(), Data([0, 0, 0, 0, 1, 0, 64, 0])] {
            let bad = fixture.directory.appendingPathComponent("truncated-record")
            try Data(data).write(to: bad)
            let corrupt = try BinaryRecordReader(url: bad, headerSize: 8, lengthOffset: 4)
            #expect(throws: (any Error).self) { try corrupt.next() }
        }
    }

    @Test
    func largeRecordsLimitMergeFanIn() throws {
        let fixture = try DatabaseFixture(count: 0)
        defer { fixture.remove() }
        let input = fixture.directory.appendingPathComponent("large-records")
        let writer = try BufferedBinaryWriter(url: input)
        for key in (0..<9).reversed() {
            try writer.write(UInt32(key))
            try writer.write(UInt32(1 << 20))
            try writer.write(Data(repeating: UInt8(key), count: 1 << 20))
        }
        _ = try writer.close()
        let sorted = try ExternalSort.sort(
            inputs: [input],
            workspace: fixture.directory,
            label: "large",
            headerSize: 8,
            lengthOffset: 4,
            memoryBytes: 8 << 20
        ) {
            $0.readUInt32(at: 0) < $1.readUInt32(at: 0)
        }
        let reader = try BinaryRecordReader(url: sorted, headerSize: 8, lengthOffset: 4)
        for key in 0..<9 {
            let record = try #require(try reader.next())
            #expect(record.withUnsafeBytes { $0.readUInt32(at: 0) } == UInt32(key))
            #expect(record.count == (1 << 20) + 8)
            #expect(record.dropFirst(8).allSatisfy { $0 == UInt8(key) })
        }
        #expect(try reader.next() == nil)
    }

    @Test
    func cachedBoostsPreservePackedBounds() {
        var summary = LengthBinnedRankBounds()
        for length in [0, 4, 8, 12, 16, 24, 32, 48, 64, 96, 128, 256] {
            summary.insert(rank: Float(length) / 256, characterCount: UInt16(length))
        }
        for populated in [false, true] {
            let bounds = populated ? summary : LengthBinnedRankBounds()
            var encoded = [UInt16]()
            bounds.append(to: &encoded)
            let bytes = encoded.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8($0 >> 8)] }
            for queryLength in 0...600 {
                for onlyExact in [false, true] {
                    let boosts = PackedRadixIndexLayout.rankBoosts(queryCharacters: queryLength, onlyExact: onlyExact)
                    bytes.withUnsafeBufferPointer { raw in
                        let actual = PackedRadixIndexLayout.rankUpperBound(
                            bytes: Span(_unsafeElements: raw), offset: 0, boosts: boosts
                        )
                        #expect(actual == bounds.upperBound(queryCharacters: queryLength, onlyExact: onlyExact))
                    }
                }
            }
        }
    }

    @Test
    func boundsCoverEveryRepresentedScore() {
        for length in [0, 3, 4, 7, 8, 11, 12, 15, 16, 23, 24, 31, 32, 47, 48, 63, 64, 95, 96, 127, 128, 255, 256, 600] {
            for rank: Float in [0, 0.1, 0.9, 1.1, 1.4] {
                var summary = LengthBinnedRankBounds()
                summary.insert(rank: rank, characterCount: UInt16(length))
                for queryLength in 0...length {
                    let actual =
                        rank
                        + SearchScorer.boost(
                            characterCount: length,
                            queryCharacters: queryLength,
                            isExact: length == queryLength
                        )
                    #expect(summary.upperBound(queryCharacters: queryLength, onlyExact: false) >= actual)
                }
            }
        }
    }
}
