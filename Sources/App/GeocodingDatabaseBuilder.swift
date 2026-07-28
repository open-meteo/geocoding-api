import Foundation
import Vapor

#if os(Linux)
import Glibc
#else
import Darwin
#endif

struct DatabaseBuildOptions {
    var memoryLimitBytes = 1 << 30
    var workers = min(ProcessInfo.processInfo.activeProcessorCount, 4)
    var force = false
}

struct DatabaseBuildPaths {
    var geonamesFile: URL
    var alternateNamesFile: URL
    var databaseFile: URL

    static let `default` = DatabaseBuildPaths(
        geonamesFile: URL(fileURLWithPath: "data/allCountries.txt"),
        alternateNamesFile: URL(fileURLWithPath: "data/alternateNamesV2.txt"),
        databaseFile: URL(fileURLWithPath: "data/database-v2.bin")
    )
}

struct DatabaseSectionArtifact {
    let kind: DatabaseSectionKind
    let url: URL
    let length: UInt64
    let count: UInt64
    let stride: UInt32
    let hash: UInt64
    var flags: UInt32 = 0
}

private struct GeoNamesScanSummary {
    var includedIDs = DynamicBitSet()
    var recordCount: UInt32 = 0
    var maximumID: UInt32 = 0
    var countries = [UInt16: Int32]()
    var administrativeCodes = AdminCodeLookup()
    var fingerprint: UInt64 = 0
}

private struct PartitionNameSlice {
    let offset: Int
    let length: Int
}

private struct PreferredAlternate {
    let preference: UInt8
    let name: PartitionNameSlice
}

private struct AlternateNamesBuildResult {
    let languages: ByteStringInterner
    let alternateStarts: [UInt32]
    let alternateCounts: [UInt16]
    let postcodeStarts: [UInt32]
    let postcodeCounts: [UInt16]
    let artifacts: [DatabaseSectionArtifact]
    let fingerprint: UInt64
}

private struct SearchCandidatePartitions {
    let urls: [URL]
    let writers: [BufferedBinaryWriter]
    let mask: UInt32

    func writer(indexID: UInt16, country: UInt16) -> BufferedBinaryWriter {
        var hash = UInt32(indexID) &* 2_654_435_761
        hash ^= UInt32(country) &* 2_246_822_519
        return writers[Int(hash & mask)]
    }
}

final class GeocodingDatabaseBuilder {
    static let geonamesFile = DatabaseBuildPaths.default.geonamesFile
    static let alternateNamesFile = DatabaseBuildPaths.default.alternateNamesFile
    static let databaseFile = DatabaseBuildPaths.default.databaseFile

    private let logger: Logger
    private let options: DatabaseBuildOptions
    private let paths: DatabaseBuildPaths
    private let fileManager = FileManager.default
    private let workspace: URL

    init(
        logger: Logger,
        options: DatabaseBuildOptions = .init(),
        paths: DatabaseBuildPaths = .default
    ) throws {
        self.logger = logger
        self.options = options
        self.paths = paths
        let dataDirectory = paths.databaseFile.deletingLastPathComponent()
        workspace = dataDirectory.appendingPathComponent(
            ".geocoding-database-build-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: workspace,
            withIntermediateDirectories: true
        )
    }

    deinit {
        try? fileManager.removeItem(at: workspace)
    }

    func build() throws {
        let started = Date()
        logger.info("Geocoding database: scan GeoNames metadata")
        let initial = try scanGeonames()
        logger.info(
            "Geocoding database: selected \(initial.recordCount) records; maximum ID \(initial.maximumID)"
        )

        logger.info("Geocoding database: partition and reduce alternate names")
        let alternate = try buildAlternateNames(initial: initial)

        logger.info("Geocoding database: write record columns and search candidates")
        let records = try buildRecords(initial: initial, alternate: alternate)

        logger.info("Geocoding database: build packed search index")
        let searchArtifacts = try PackedRadixIndexBuilder(
            logger: logger,
            workspace: workspace,
            sourcePartitions: records.searchPartitions
        ).build()

        var artifacts = alternate.artifacts
        artifacts.append(contentsOf: records.artifacts)
        artifacts.append(contentsOf: searchArtifacts)
        artifacts.append(
            try writeStringTable(
                kind: .featureStrings,
                values: GeoNamesRecordRules.includedFeatureNames
            )
        )
        artifacts.append(
            try writeStringTable(
                kind: .timezoneStrings,
                values: records.timezones.strings
            )
        )
        artifacts.append(
            try writeStringTable(
                kind: .languageStrings,
                values: alternate.languages.strings
            )
        )

        logger.info("Geocoding database: assemble \(artifacts.count) sections")
        try assemble(
            artifacts: artifacts,
            recordCount: initial.recordCount,
            maximumID: initial.maximumID,
            geonamesFingerprint: initial.fingerprint,
            alternateNamesFingerprint: alternate.fingerprint
        )
        logger.info(
            "Geocoding database: finished in \(Date().timeIntervalSince(started)) seconds"
        )
    }

    private func scanGeonames() throws -> GeoNamesScanSummary {
        var result = GeoNamesScanSummary()
        var hasher = XXHash64()
        let reader = try BufferedLineReader(url: paths.geonamesFile)
        var lineNumber = 0

        try reader.forEachLine(hasher: &hasher) { line in
            lineNumber += 1
            guard !line.isEmpty else {
                return
            }
            var fields = TSVLineScanner(line)
            let idBytes = try fields.next(file: reader.path, lineNumber: lineNumber)
            guard
                let unsignedID = idBytes.unsignedInteger,
                unsignedID <= UInt32(Int32.max)
            else {
                throw GeoNamesImportError.identifierOutOfRange(
                    file: reader.path,
                    line: lineNumber
                )
            }
            try fields.skip(6, file: reader.path, lineNumber: lineNumber)
            let feature = try fields.next(file: reader.path, lineNumber: lineNumber)
            let countryBytes = try fields.next(file: reader.path, lineNumber: lineNumber)
            _ = try fields.next(file: reader.path, lineNumber: lineNumber)
            let admin1 = try fields.next(file: reader.path, lineNumber: lineNumber)
            let admin2 = try fields.next(file: reader.path, lineNumber: lineNumber)
            let admin3 = try fields.next(file: reader.path, lineNumber: lineNumber)
            let admin4 = try fields.next(file: reader.path, lineNumber: lineNumber)

            guard GeoNamesRecordRules.includes(feature) else {
                return
            }
            result.includedIDs.insert(unsignedID)
            result.recordCount += 1
            result.maximumID = max(result.maximumID, unsignedID)

            let country = countryBytes.iso2
            let id = Int32(unsignedID)
            let codes = [admin1, admin2, admin3, admin4]
            if feature.equalsASCII("ADM1") {
                result.administrativeCodes.insert(
                    level: 0,
                    country: country,
                    codes: codes,
                    geonameID: id
                )
            } else if feature.equalsASCII("ADM2") {
                result.administrativeCodes.insert(
                    level: 1,
                    country: country,
                    codes: codes,
                    geonameID: id
                )
            } else if feature.equalsASCII("ADM3") {
                result.administrativeCodes.insert(
                    level: 2,
                    country: country,
                    codes: codes,
                    geonameID: id
                )
            } else if feature.equalsASCII("ADM4") {
                result.administrativeCodes.insert(
                    level: 3,
                    country: country,
                    codes: codes,
                    geonameID: id
                )
            }
            if feature.equalsASCII("PCLI") {
                result.countries[country] = id
            }
        }
        result.fingerprint = hasher.digest()
        return result
    }

    private func buildAlternateNames(initial: GeoNamesScanSummary) throws -> AlternateNamesBuildResult {
        let partitionCount = try alternatePartitionCount()
        let partitionMask = UInt32(partitionCount - 1)
        var partitionWriters = [BufferedBinaryWriter]()
        var partitionURLs = [URL]()
        partitionWriters.reserveCapacity(partitionCount)
        partitionURLs.reserveCapacity(partitionCount)
        for index in 0..<partitionCount {
            let url = workspace.appendingPathComponent("alternate-\(index).part")
            partitionURLs.append(url)
            partitionWriters.append(try BufferedBinaryWriter(url: url))
        }

        let languages = ByteStringInterner()
        var fingerprintHasher = XXHash64()
        let reader = try BufferedLineReader(url: paths.alternateNamesFile)
        var lineNumber = 0
        try reader.forEachLine(hasher: &fingerprintHasher) { line in
            lineNumber += 1
            guard !line.isEmpty else {
                return
            }
            var fields = TSVLineScanner(line)
            _ = try fields.next(file: reader.path, lineNumber: lineNumber)
            let idBytes = try fields.next(file: reader.path, lineNumber: lineNumber)
            let languageBytes = try fields.next(file: reader.path, lineNumber: lineNumber)
            let name = try fields.next(file: reader.path, lineNumber: lineNumber)
            let preferred = try fields.next(file: reader.path, lineNumber: lineNumber)
            let short = try fields.next(file: reader.path, lineNumber: lineNumber)
            let colloquial = try fields.next(file: reader.path, lineNumber: lineNumber)
            let historic = try fields.next(file: reader.path, lineNumber: lineNumber)

            guard let id = idBytes.unsignedInteger else {
                throw GeoNamesImportError.invalidInteger(
                    file: reader.path,
                    line: lineNumber,
                    field: 2
                )
            }
            if languageBytes.equalsASCII("link")
                || languageBytes.equalsASCII("wkdt")
                || languageBytes.equalsASCII("fr_1793")
                || colloquial.unsignedInteger == 1
                || historic.unsignedInteger == 1
            {
                return
            }

            let isPostcode = languageBytes.equalsASCII("post")
            let languageID: UInt16
            if isPostcode {
                languageID = 0
            } else {
                languageID = try languages.findOrInsert(
                    languageBytes,
                    file: reader.path,
                    line: lineNumber,
                    field: 3
                )
            }
            guard initial.includedIDs.contains(id) else {
                return
            }

            let preference: UInt8
            if preferred.unsignedInteger == 1, short.unsignedInteger == 1 {
                preference = 4
            } else if preferred.unsignedInteger == 1 {
                preference = 3
            } else if short.unsignedInteger == 1 {
                preference = 2
            } else {
                preference = 1
            }
            let writer = partitionWriters[Int(id & partitionMask)]
            try writer.write(id)
            try writer.write(languageID)
            try writer.write(isPostcode ? UInt8(1) : UInt8(0))
            try writer.write(preference)
            try writer.write(UInt32(name.count))
            try writer.write(name)
        }
        for writer in partitionWriters {
            _ = try writer.close()
        }

        let denseCount = Int(initial.maximumID) + 1
        var alternateStarts = [UInt32](repeating: 0, count: denseCount)
        var alternateCounts = [UInt16](repeating: 0, count: denseCount)
        var postcodeStarts = [UInt32](repeating: 0, count: denseCount)
        var postcodeCounts = [UInt16](repeating: 0, count: denseCount)

        let alternateRecordsURL = workspace.appendingPathComponent("alternate-records.section")
        let alternateStringsURL = workspace.appendingPathComponent("alternate-strings.section")
        let postcodeOffsetsURL = workspace.appendingPathComponent("postcode-offsets.section")
        let postcodeStringsURL = workspace.appendingPathComponent("postcode-strings.section")
        let alternateRecords = try BufferedBinaryWriter(url: alternateRecordsURL)
        let alternateStrings = try BufferedBinaryWriter(url: alternateStringsURL)
        let postcodeOffsets = try BufferedBinaryWriter(url: postcodeOffsetsURL)
        let postcodeStrings = try BufferedBinaryWriter(url: postcodeStringsURL)
        var alternateRecordCount: UInt32 = 0
        var postcodeRecordCount: UInt32 = 0

        for (index, url) in partitionURLs.enumerated() {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            if (attributes[.size] as? NSNumber)?.uint64Value == 0 {
                try fileManager.removeItem(at: url)
                continue
            }
            logger.info(
                "Alternate names: reduce partition \(index + 1)/\(partitionCount)"
            )
            try {
                let mapped = try MappedFile(url: url)
                let bytes = try mapped.bytes(offset: 0, length: UInt64(mapped.count))
                var preferredByKey = [UInt64: PreferredAlternate]()
                var postcodesByID = [UInt32: [PartitionNameSlice]]()
                var offset = 0
                while offset < bytes.count {
                    guard offset + 12 <= bytes.count else {
                        throw DatabaseBuildIOError.read(
                            path: url.path,
                            message: "truncated alternate partition record"
                        )
                    }
                    let id = bytes.readUInt32(at: offset)
                    let languageID = bytes.readUInt16(at: offset + 4)
                    let kind = bytes[offset + 6]
                    let preference = bytes[offset + 7]
                    let nameLength = Int(bytes.readUInt32(at: offset + 8))
                    let nameOffset = offset + 12
                    guard nameLength <= bytes.count - nameOffset else {
                        throw DatabaseBuildIOError.read(
                            path: url.path,
                            message: "alternate partition string exceeds file"
                        )
                    }
                    let slice = PartitionNameSlice(
                        offset: nameOffset,
                        length: nameLength
                    )
                    if kind == 1 {
                        postcodesByID[id, default: []].append(slice)
                    } else {
                        let key = UInt64(id) << 16 | UInt64(languageID)
                        if preferredByKey[key] == nil
                            || preferredByKey[key]!.preference < preference
                        {
                            preferredByKey[key] = PreferredAlternate(
                                preference: preference,
                                name: slice
                            )
                        }
                    }
                    offset = nameOffset + nameLength
                }

                let sortedKeys = preferredByKey.keys.sorted()
                var keyOffset = 0
                while keyOffset < sortedKeys.count {
                    let id = UInt32(sortedKeys[keyOffset] >> 16)
                    let start = alternateRecordCount
                    var cursor = keyOffset
                    while cursor < sortedKeys.count,
                        UInt32(sortedKeys[cursor] >> 16) == id
                    {
                        let key = sortedKeys[cursor]
                        let languageID = UInt16(truncatingIfNeeded: key)
                        let candidate = preferredByKey[key]!
                        let stringOffset = try alternateStrings.currentUInt32Offset()
                        try alternateStrings.write(UInt32(candidate.name.length))
                        let nameEnd = candidate.name.offset + candidate.name.length
                        try alternateStrings.write(
                            UnsafeRawBufferPointer(
                                rebasing: bytes[candidate.name.offset..<nameEnd]
                            )
                        )
                        try alternateRecords.write(languageID)
                        try alternateRecords.write(stringOffset)
                        alternateRecordCount += 1
                        cursor += 1
                    }
                    let count = cursor - keyOffset
                    guard let compactCount = UInt16(exactly: count) else {
                        throw GeoNamesImportError.tooManyValues(
                            "alternate names for geoname \(id)"
                        )
                    }
                    alternateStarts[Int(id)] = start
                    alternateCounts[Int(id)] = compactCount
                    keyOffset = cursor
                }

                for id in postcodesByID.keys.sorted() {
                    let values = postcodesByID[id]!
                    guard let compactCount = UInt16(exactly: values.count) else {
                        throw GeoNamesImportError.tooManyValues(
                            "postcodes for geoname \(id)"
                        )
                    }
                    postcodeStarts[Int(id)] = postcodeRecordCount
                    postcodeCounts[Int(id)] = compactCount
                    for value in values {
                        let stringOffset = try postcodeStrings.currentUInt32Offset()
                        try postcodeStrings.write(UInt32(value.length))
                        try postcodeStrings.write(
                            UnsafeRawBufferPointer(
                                rebasing: bytes[
                                    value.offset..<value.offset + value.length
                                ]
                            )
                        )
                        try postcodeOffsets.write(stringOffset)
                        postcodeRecordCount += 1
                    }
                }
            }()
            try fileManager.removeItem(at: url)
        }

        let alternateRecordsResult = try alternateRecords.close()
        let alternateStringsResult = try alternateStrings.close()
        let postcodeOffsetsResult = try postcodeOffsets.close()
        let postcodeStringsResult = try postcodeStrings.close()
        let artifacts = [
            DatabaseSectionArtifact(
                kind: .alternateRecords,
                url: alternateRecordsURL,
                length: alternateRecordsResult.length,
                count: UInt64(alternateRecordCount),
                stride: 6,
                hash: alternateRecordsResult.hash
            ),
            DatabaseSectionArtifact(
                kind: .alternateStrings,
                url: alternateStringsURL,
                length: alternateStringsResult.length,
                count: alternateStringsResult.length,
                stride: 1,
                hash: alternateStringsResult.hash
            ),
            DatabaseSectionArtifact(
                kind: .postcodeOffsets,
                url: postcodeOffsetsURL,
                length: postcodeOffsetsResult.length,
                count: UInt64(postcodeRecordCount),
                stride: 4,
                hash: postcodeOffsetsResult.hash
            ),
            DatabaseSectionArtifact(
                kind: .postcodeStrings,
                url: postcodeStringsURL,
                length: postcodeStringsResult.length,
                count: postcodeStringsResult.length,
                stride: 1,
                hash: postcodeStringsResult.hash
            ),
        ]
        return AlternateNamesBuildResult(
            languages: languages,
            alternateStarts: alternateStarts,
            alternateCounts: alternateCounts,
            postcodeStarts: postcodeStarts,
            postcodeCounts: postcodeCounts,
            artifacts: artifacts,
            fingerprint: fingerprintHasher.digest()
        )
    }

    private struct RecordBuildOutput {
        let artifacts: [DatabaseSectionArtifact]
        let timezones: ByteStringInterner
        let searchPartitions: [URL]
    }

    private func buildRecords(
        initial: GeoNamesScanSummary,
        alternate: AlternateNamesBuildResult
    ) throws -> RecordBuildOutput {
        let columnDefinitions: [(DatabaseSectionKind, UInt32)] = [
            (.rowToID, 4), (.latitude, 4), (.longitude, 4), (.ranking, 4),
            (.elevation, 2), (.feature, 1), (.countryISO2, 2), (.countryID, 4),
            (.admin1ID, 4), (.admin2ID, 4), (.admin3ID, 4), (.admin4ID, 4),
            (.timezoneIndex, 2), (.population, 4), (.nameOffset, 4),
            (.alternateStart, 4), (.alternateCount, 2), (.postcodeStart, 4),
            (.postcodeCount, 2),
        ]
        var columnWriters = [DatabaseSectionKind: BufferedBinaryWriter]()
        for (kind, _) in columnDefinitions {
            columnWriters[kind] = try BufferedBinaryWriter(
                url: workspace.appendingPathComponent("\(kind).section")
            )
        }
        let canonicalStringsURL = workspace.appendingPathComponent("canonical-strings.section")
        let canonicalStrings = try BufferedBinaryWriter(url: canonicalStringsURL)
        let timezones = ByteStringInterner()
        var idToRow = [UInt32](
            repeating: UInt32.max,
            count: Int(initial.maximumID) + 1
        )

        let alternateRecordsArtifact = alternate.artifacts.first {
            $0.kind == .alternateRecords
        }!
        let alternateStringsArtifact = alternate.artifacts.first {
            $0.kind == .alternateStrings
        }!
        let postcodeOffsetsArtifact = alternate.artifacts.first {
            $0.kind == .postcodeOffsets
        }!
        let postcodeStringsArtifact = alternate.artifacts.first {
            $0.kind == .postcodeStrings
        }!
        let alternateRecordsMap = try MappedFile(url: alternateRecordsArtifact.url)
        let alternateStringsMap = try MappedFile(url: alternateStringsArtifact.url)
        let postcodeOffsetsMap = try MappedFile(url: postcodeOffsetsArtifact.url)
        let postcodeStringsMap = try MappedFile(url: postcodeStringsArtifact.url)
        let alternateRecordBytes = try alternateRecordsMap.bytes(
            offset: 0,
            length: UInt64(alternateRecordsMap.count)
        )
        let alternateStringBytes = try alternateStringsMap.bytes(
            offset: 0,
            length: UInt64(alternateStringsMap.count)
        )
        let postcodeOffsetBytes = try postcodeOffsetsMap.bytes(
            offset: 0,
            length: UInt64(postcodeOffsetsMap.count)
        )
        let postcodeStringBytes = try postcodeStringsMap.bytes(
            offset: 0,
            length: UInt64(postcodeStringsMap.count)
        )

        let searchPartitionCount = 32
        var searchWriters = [BufferedBinaryWriter]()
        var searchURLs = [URL]()
        for index in 0..<searchPartitionCount {
            let url = workspace.appendingPathComponent("search-\(index).part")
            searchURLs.append(url)
            searchWriters.append(try BufferedBinaryWriter(url: url))
        }
        let searchPartitions = SearchCandidatePartitions(
            urls: searchURLs,
            writers: searchWriters,
            mask: UInt32(searchPartitionCount - 1)
        )
        let emptyLanguage = alternate.languages.firstIndex(of: "")
        let iataLanguage = alternate.languages.firstIndex(of: "iata")
        let icaoLanguage = alternate.languages.firstIndex(of: "icao")

        var ignoredFingerprint = XXHash64()
        let reader = try BufferedLineReader(url: paths.geonamesFile)
        var lineNumber = 0
        var row: UInt32 = 0
        try reader.forEachLine(hasher: &ignoredFingerprint) { line in
            lineNumber += 1
            guard !line.isEmpty else {
                return
            }
            var fields = TSVLineScanner(line)
            let idBytes = try fields.next(file: reader.path, lineNumber: lineNumber)
            let name = try fields.next(file: reader.path, lineNumber: lineNumber)
            _ = try fields.next(file: reader.path, lineNumber: lineNumber)
            _ = try fields.next(file: reader.path, lineNumber: lineNumber)
            let latitudeBytes = try fields.next(file: reader.path, lineNumber: lineNumber)
            let longitudeBytes = try fields.next(file: reader.path, lineNumber: lineNumber)
            _ = try fields.next(file: reader.path, lineNumber: lineNumber)
            let feature = try fields.next(file: reader.path, lineNumber: lineNumber)
            let countryBytes = try fields.next(file: reader.path, lineNumber: lineNumber)
            _ = try fields.next(file: reader.path, lineNumber: lineNumber)
            let admin1 = try fields.next(file: reader.path, lineNumber: lineNumber)
            let admin2 = try fields.next(file: reader.path, lineNumber: lineNumber)
            let admin3 = try fields.next(file: reader.path, lineNumber: lineNumber)
            let admin4 = try fields.next(file: reader.path, lineNumber: lineNumber)
            let populationBytes = try fields.next(file: reader.path, lineNumber: lineNumber)
            let elevationBytes = try fields.next(file: reader.path, lineNumber: lineNumber)
            let demBytes = try fields.next(file: reader.path, lineNumber: lineNumber)
            let timezoneBytes = try fields.next(file: reader.path, lineNumber: lineNumber)

            guard
                let id = idBytes.unsignedInteger,
                initial.includedIDs.contains(id)
            else {
                return
            }
            guard let featureIndex = GeoNamesRecordRules.featureIndex(feature) else {
                return
            }
            guard let latitude = latitudeBytes.decimalFloat else {
                throw GeoNamesImportError.invalidFloat(
                    file: reader.path,
                    line: lineNumber,
                    field: 5
                )
            }
            guard let longitude = longitudeBytes.decimalFloat else {
                throw GeoNamesImportError.invalidFloat(
                    file: reader.path,
                    line: lineNumber,
                    field: 6
                )
            }
            guard let population = populationBytes.unsignedInteger else {
                throw GeoNamesImportError.invalidInteger(
                    file: reader.path,
                    line: lineNumber,
                    field: 15
                )
            }
            let elevation =
                elevationBytes.isEmpty
                ? (demBytes.signedInt16 ?? 0)
                : (elevationBytes.signedInt16 ?? 0)
            let timezone = try timezones.findOrInsert(
                timezoneBytes,
                file: reader.path,
                line: lineNumber,
                field: 18
            )
            let country = countryBytes.iso2
            let codes = [admin1, admin2, admin3, admin4]
            let admin1ID = initial.administrativeCodes.find(
                level: 0,
                country: country,
                codes: codes
            )
            let admin2ID = initial.administrativeCodes.find(
                level: 1,
                country: country,
                codes: codes
            )
            let admin3ID = initial.administrativeCodes.find(
                level: 2,
                country: country,
                codes: codes
            )
            let admin4ID = initial.administrativeCodes.find(
                level: 3,
                country: country,
                codes: codes
            )
            let alternateStart = alternate.alternateStarts[Int(id)]
            let alternateCount = alternate.alternateCounts[Int(id)]
            let postcodeStart = alternate.postcodeStarts[Int(id)]
            let postcodeCount = alternate.postcodeCounts[Int(id)]
            let rank = GeoNamesRecordRules.ranking(
                population: population,
                feature: feature,
                hasPostcode: postcodeCount > 0
            )
            let nameOffset = try canonicalStrings.currentUInt32Offset()
            try canonicalStrings.write(UInt32(name.count))
            try canonicalStrings.write(name)

            idToRow[Int(id)] = row
            try columnWriters[.rowToID]!.write(id)
            try columnWriters[.latitude]!.write(latitude)
            try columnWriters[.longitude]!.write(longitude)
            try columnWriters[.ranking]!.write(rank)
            try columnWriters[.elevation]!.write(elevation)
            try columnWriters[.feature]!.write(featureIndex)
            try columnWriters[.countryISO2]!.write(country)
            try columnWriters[.countryID]!.write(
                initial.countries[country] ?? 0
            )
            try columnWriters[.admin1ID]!.write(admin1ID)
            try columnWriters[.admin2ID]!.write(admin2ID)
            try columnWriters[.admin3ID]!.write(admin3ID)
            try columnWriters[.admin4ID]!.write(admin4ID)
            try columnWriters[.timezoneIndex]!.write(timezone)
            try columnWriters[.population]!.write(population)
            try columnWriters[.nameOffset]!.write(nameOffset)
            try columnWriters[.alternateStart]!.write(alternateStart)
            try columnWriters[.alternateCount]!.write(alternateCount)
            try columnWriters[.postcodeStart]!.write(postcodeStart)
            try columnWriters[.postcodeCount]!.write(postcodeCount)

            if GeoNamesRecordRules.includeInSearchIndex(featureIndex: featureIndex) {
                try emitSearchCandidate(
                    bytes: name,
                    indexID: 0,
                    country: country,
                    admin1ID: admin1ID,
                    row: row,
                    ranking: rank,
                    partitions: searchPartitions
                )
                for alternateIndex in 0..<Int(alternateCount) {
                    let record = (Int(alternateStart) + alternateIndex) * 6
                    let languageID = alternateRecordBytes.readUInt16(at: record)
                    let offset = alternateRecordBytes.readUInt32(at: record + 2)
                    let alternateName = try stringBytes(
                        in: alternateStringBytes,
                        offset: offset,
                        section: .alternateStrings
                    )
                    if languageID != emptyLanguage {
                        guard languageID < UInt16.max else {
                            throw GeoNamesImportError.tooManyLanguages
                        }
                        try emitSearchCandidate(
                            bytes: alternateName,
                            indexID: languageID + 1,
                            country: country,
                            admin1ID: admin1ID,
                            row: row,
                            ranking: rank,
                            partitions: searchPartitions
                        )
                    }
                    if languageID == emptyLanguage
                        || languageID == iataLanguage
                        || languageID == icaoLanguage
                    {
                        try emitSearchCandidate(
                            bytes: alternateName,
                            indexID: 0,
                            country: country,
                            admin1ID: admin1ID,
                            row: row,
                            ranking: rank,
                            partitions: searchPartitions
                        )
                    }
                }
                for postcodeIndex in 0..<Int(postcodeCount) {
                    let offsetIndex = Int(postcodeStart) + postcodeIndex
                    let offset = postcodeOffsetBytes.readUInt32(at: offsetIndex * 4)
                    let postcode = try stringBytes(
                        in: postcodeStringBytes,
                        offset: offset,
                        section: .postcodeStrings
                    )
                    try emitSearchCandidate(
                        bytes: postcode,
                        indexID: 0,
                        country: country,
                        admin1ID: admin1ID,
                        row: row,
                        ranking: rank,
                        partitions: searchPartitions
                    )
                }
            }
            row += 1
        }
        guard row == initial.recordCount else {
            throw DatabaseFormatError.invalidHeader(
                "record scan produced \(row), expected \(initial.recordCount)"
            )
        }

        var artifacts = [DatabaseSectionArtifact]()
        for (kind, stride) in columnDefinitions {
            let writer = columnWriters[kind]!
            let result = try writer.close()
            artifacts.append(
                DatabaseSectionArtifact(
                    kind: kind,
                    url: writer.url,
                    length: result.length,
                    count: UInt64(initial.recordCount),
                    stride: stride,
                    hash: result.hash
                )
            )
        }
        let canonicalResult = try canonicalStrings.close()
        artifacts.append(
            DatabaseSectionArtifact(
                kind: .canonicalStrings,
                url: canonicalStringsURL,
                length: canonicalResult.length,
                count: canonicalResult.length,
                stride: 1,
                hash: canonicalResult.hash
            )
        )
        artifacts.append(try writeDenseIDMap(idToRow))
        for writer in searchWriters {
            _ = try writer.close()
        }
        return RecordBuildOutput(
            artifacts: artifacts,
            timezones: timezones,
            searchPartitions: searchURLs
        )
    }

    private func emitSearchCandidate(
        bytes: UnsafeRawBufferPointer,
        indexID: UInt16,
        country: UInt16,
        admin1ID: Int32,
        row: UInt32,
        ranking: Float,
        partitions: SearchCandidatePartitions
    ) throws {
        guard let value = String(bytes: bytes, encoding: .utf8) else {
            throw DatabaseFormatError.invalidSection(
                .searchEdgeLabels,
                "search name is not valid UTF-8"
            )
        }
        let normalized =
            value
            .folding(options: .diacriticInsensitive, locale: nil)
            .lowercased()
        guard
            let characterCount = UInt16(exactly: normalized.count),
            let byteCount = UInt32(exactly: normalized.utf8.count)
        else {
            throw GeoNamesImportError.tooManyValues("characters in a search name")
        }
        let writer = partitions.writer(indexID: indexID, country: country)
        try writer.write(indexID)
        try writer.write(country)
        try writer.write(admin1ID)
        try writer.write(row)
        try writer.write(ranking)
        try writer.write(characterCount)
        try writer.write(UInt16(0))
        try writer.write(byteCount)
        let normalizedBytes = Array(normalized.utf8)
        try normalizedBytes.withUnsafeBytes {
            try writer.write($0)
        }
    }

    private func stringBytes(
        in pool: UnsafeRawBufferPointer,
        offset: UInt32,
        section: DatabaseSectionKind
    ) throws -> UnsafeRawBufferPointer {
        let position = Int(offset)
        guard position + 4 <= pool.count else {
            throw DatabaseFormatError.invalidStringOffset(section: section, offset: offset)
        }
        let length = Int(pool.readUInt32(at: position))
        guard length <= pool.count - position - 4 else {
            throw DatabaseFormatError.invalidStringOffset(section: section, offset: offset)
        }
        return UnsafeRawBufferPointer(
            rebasing: pool[position + 4..<position + 4 + length]
        )
    }

    private func writeDenseIDMap(_ values: [UInt32]) throws -> DatabaseSectionArtifact {
        let url = workspace.appendingPathComponent("id-to-row.section")
        let writer = try BufferedBinaryWriter(url: url)
        for value in values {
            try writer.write(value)
        }
        let result = try writer.close()
        return DatabaseSectionArtifact(
            kind: .idToRow,
            url: url,
            length: result.length,
            count: UInt64(values.count),
            stride: 4,
            hash: result.hash
        )
    }

    private func writeStringTable(
        kind: DatabaseSectionKind,
        values: [String]
    ) throws -> DatabaseSectionArtifact {
        let url = workspace.appendingPathComponent("\(kind).section")
        let writer = try BufferedBinaryWriter(url: url)
        for value in values {
            _ = try writer.writeLengthPrefixed(value)
        }
        let result = try writer.close()
        return DatabaseSectionArtifact(
            kind: kind,
            url: url,
            length: result.length,
            count: UInt64(values.count),
            stride: 0,
            hash: result.hash
        )
    }

    private func alternatePartitionCount() throws -> Int {
        let attributes = try fileManager.attributesOfItem(
            atPath: paths.alternateNamesFile.path
        )
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let target = max(16 << 20, options.memoryLimitBytes / 8)
        var partitions = 16
        while size / partitions > target {
            partitions *= 2
        }
        return partitions
    }

    private func assemble(
        artifacts: [DatabaseSectionArtifact],
        recordCount: UInt32,
        maximumID: UInt32,
        geonamesFingerprint: UInt64,
        alternateNamesFingerprint: UInt64
    ) throws {
        let output = workspace.appendingPathComponent("database-v2.bin.tmp")
        guard fileManager.createFile(atPath: output.path, contents: nil) else {
            throw DatabaseBuildIOError.open(path: output.path, message: "createFile failed")
        }
        let handle = try FileHandle(forWritingTo: output)
        try handle.write(contentsOf: Data(repeating: 0, count: DatabaseFileHeader.encodedSize))
        var currentOffset = UInt64(DatabaseFileHeader.encodedSize)
        var descriptors = [DatabaseSectionDescriptor]()

        for artifact in artifacts.sorted(by: { $0.kind.rawValue < $1.kind.rawValue }) {
            let aligned = (currentOffset + 4095) & ~UInt64(4095)
            if aligned > currentOffset {
                try handle.write(
                    contentsOf: Data(
                        repeating: 0,
                        count: Int(aligned - currentOffset)
                    )
                )
            }
            currentOffset = aligned
            let source = try FileHandle(forReadingFrom: artifact.url)
            while true {
                let data = try source.read(upToCount: 4 << 20) ?? Data()
                if data.isEmpty {
                    break
                }
                try handle.write(contentsOf: data)
            }
            try source.close()
            descriptors.append(
                DatabaseSectionDescriptor(
                    kind: artifact.kind,
                    flags: artifact.flags,
                    offset: currentOffset,
                    length: artifact.length,
                    count: artifact.count,
                    stride: artifact.stride,
                    hash: artifact.hash
                )
            )
            currentOffset += artifact.length
        }

        let header = try DatabaseFileHeader(
            fileSize: currentOffset,
            recordCount: recordCount,
            maximumGeonameID: maximumID,
            geonamesFingerprint: geonamesFingerprint,
            alternateNamesFingerprint: alternateNamesFingerprint,
            sectionDescriptors: descriptors
        )
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: header.encoded())
        try handle.synchronize()
        try handle.close()
        _ = try DatabaseFileHeader(mappedFile: MappedFile(url: output))

        let destination = paths.databaseFile.path
        guard rename(output.path, destination) == 0 else {
            throw DatabaseBuildIOError.write(
                path: destination,
                message: String(cString: strerror(errno))
            )
        }
    }
}
