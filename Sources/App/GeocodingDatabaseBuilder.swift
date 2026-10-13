import Foundation
import Vapor

#if os(Linux)
import Glibc
#else
import Darwin
#endif

struct DatabaseBuildOptions {
    var memoryLimitBytes = 1 << 30
    var force = false
}

struct DatabaseBuildPaths {
    var geonamesFile: URL
    var alternateNamesFile: URL
    var databaseFile: URL

    static let `default` = DatabaseBuildPaths(
        geonamesFile: URL(fileURLWithPath: "data/allCountries.txt"),
        alternateNamesFile: URL(fileURLWithPath: "data/alternateNamesV2.txt"),
        databaseFile: URL(fileURLWithPath: "data/database-v1.bin")
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
    var idToRow = [UInt32]()

    var managedBytes: Int {
        (Int(maximumID) + 1) * 4 + Int(recordCount) * 12 + (Int(maximumID) + 8) / 8 + (32 << 20)
    }
    var recordCount: UInt32 = 0
    var maximumID: UInt32 = 0
    var countries = [UInt16: Int32]()
    var administrativeCodes = AdminCodeLookup()
    var fingerprint: UInt64 = 0
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

private struct AdministrativeAliasBuildKey: Hashable {
    let kind: AdministrativeAliasKind
    let languageID: UInt16
    let name: String
}

private struct AdministrativeAliasBuildCandidate: Hashable {
    let admin1ID: UInt32
    let country: UInt16
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

    func build() async throws {
        if fileManager.fileExists(atPath: paths.databaseFile.path), !options.force {
            throw DatabaseBuildIOError.write(
                path: paths.databaseFile.path,
                message: "Database already exists; pass --force to replace it"
            )
        }
        let started = Date()
        logger.info("Geocoding database: scan GeoNames metadata")
        let initial = try scanGeonames()
        logger.info(
            "Geocoding database: selected \(initial.recordCount) records; maximum ID \(initial.maximumID)"
        )

        logger.info(
            "Geocoding database: reserved managed memory \(initial.managedBytes >> 20) MiB; sort workspace \((options.memoryLimitBytes - initial.managedBytes) >> 20) MiB"
        )
        logger.info("Geocoding database: partition and reduce alternate names")
        let alternate = try buildAlternateNames(initial: initial)

        logger.info(
            "Geocoding database: write location records, search candidates, and administrative aliases"
        )
        let records = try buildRecords(initial: initial, alternate: alternate)

        logger.info("Geocoding database: build packed search index")
        let searchArtifacts = try PackedRadixIndexBuilder(
            logger: logger,
            workspace: workspace,
            source: records.searchCandidates,
            memoryLimitBytes: options.memoryLimitBytes - initial.managedBytes
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

        let output = workspace.appendingPathComponent("database-v1.bin.tmp")
        try writeContainer(
            output: output,
            artifacts: artifacts,
            recordCount: initial.recordCount,
            maximumID: initial.maximumID,
            geonamesFingerprint: initial.fingerprint,
            alternateNamesFingerprint: alternate.fingerprint
        )
        _ = try GeocodingDatabase(url: output)

        logger.info("Geocoding database: assemble \(artifacts.count) sections")
        try publish(output: output)
        logger.info(
            "Geocoding database: finished in \(Date().timeIntervalSince(started)) seconds"
        )
    }

    private func scanGeonames() throws -> GeoNamesScanSummary {
        var result = GeoNamesScanSummary()
        var ids = [UInt32]()
        var hasher = XXHash64()
        let reader = try BufferedLineReader(url: paths.geonamesFile)
        var lineNumber = 0

        try reader.forEachLine(hasher: &hasher) { line in
            lineNumber += 1
            guard !line.isEmpty else {
                return
            }
            let fields = TSVLineScanner(line)
            var fieldCursor = TSVFieldCursor()
            let idBytes = try fields.next(
                &fieldCursor,
                file: reader.path,
                lineNumber: lineNumber
            )
            guard
                let unsignedID = idBytes.unsignedInteger,
                unsignedID <= UInt32(Int32.max)
            else {
                throw GeoNamesImportError.identifierOutOfRange(
                    file: reader.path,
                    line: lineNumber
                )
            }
            try fields.skip(
                &fieldCursor,
                6,
                file: reader.path,
                lineNumber: lineNumber
            )
            let feature = try fields.next(&fieldCursor, file: reader.path, lineNumber: lineNumber)
            let countryBytes = try fields.next(&fieldCursor, file: reader.path, lineNumber: lineNumber)
            _ = try fields.next(&fieldCursor, file: reader.path, lineNumber: lineNumber)
            let admin1 = try fields.next(&fieldCursor, file: reader.path, lineNumber: lineNumber)
            let admin2 = try fields.next(&fieldCursor, file: reader.path, lineNumber: lineNumber)
            let admin3 = try fields.next(&fieldCursor, file: reader.path, lineNumber: lineNumber)
            let admin4 = try fields.next(&fieldCursor, file: reader.path, lineNumber: lineNumber)

            guard GeoNamesRecordRules.includes(feature) else {
                return
            }
            guard !result.includedIDs.contains(unsignedID) else {
                throw DatabaseFormatError.invalidHeader("duplicate GeoNames ID")
            }
            let denseBytes = (Int(max(result.maximumID, unsignedID)) + 1) * 4
            let rowBytes = (Int(result.recordCount) + 1) * 16
            let minimum = denseBytes + rowBytes + (Int(unsignedID) + 8) / 8 + 41_943_040
            guard minimum <= options.memoryLimitBytes else {
                throw DatabaseBuildIOError.write(
                    path: paths.databaseFile.path,
                    message:
                        "Memory budget is too small; at least \((minimum + (1 << 20) - 1) >> 20) MiB required for records and an 8 MiB sort workspace"
                )
            }
            ids.append(unsignedID)
            result.includedIDs.insert(unsignedID)
            result.recordCount += 1
            result.maximumID = max(result.maximumID, unsignedID)

            let country = countryBytes.iso2
            let id = Int32(unsignedID)
            if feature.equalsASCII("ADM1") {
                result.administrativeCodes.insert(
                    level: 0,
                    country: country,
                    code1: admin1,
                    code2: admin2,
                    code3: admin3,
                    code4: admin4,
                    geonameID: id
                )
            } else if feature.equalsASCII("ADM2") {
                result.administrativeCodes.insert(
                    level: 1,
                    country: country,
                    code1: admin1,
                    code2: admin2,
                    code3: admin3,
                    code4: admin4,
                    geonameID: id
                )
            } else if feature.equalsASCII("ADM3") {
                result.administrativeCodes.insert(
                    level: 2,
                    country: country,
                    code1: admin1,
                    code2: admin2,
                    code3: admin3,
                    code4: admin4,
                    geonameID: id
                )
            } else if feature.equalsASCII("ADM4") {
                result.administrativeCodes.insert(
                    level: 3,
                    country: country,
                    code1: admin1,
                    code2: admin2,
                    code3: admin3,
                    code4: admin4,
                    geonameID: id
                )
            }
            if feature.equalsASCII("PCLI") {
                result.countries[country] = id
            }
        }
        result.idToRow = [UInt32](repeating: UInt32.max, count: Int(result.maximumID) + 1)
        for (row, id) in ids.enumerated() { result.idToRow[Int(id)] = UInt32(row) }
        result.fingerprint = hasher.digest()
        return result
    }

    private func buildAlternateNames(initial: GeoNamesScanSummary) throws -> AlternateNamesBuildResult {
        let unsorted = workspace.appendingPathComponent("alternate-input.tmp")
        let inputWriter = try BufferedBinaryWriter(url: unsorted)
        let languages = ByteStringInterner()
        var fingerprintHasher = XXHash64()
        let reader = try BufferedLineReader(url: paths.alternateNamesFile)
        var lineNumber = 0
        try reader.forEachLine(hasher: &fingerprintHasher) { line in
            lineNumber += 1
            guard !line.isEmpty else {
                return
            }
            let fields = TSVLineScanner(line)
            var fieldCursor = TSVFieldCursor()
            _ = try fields.next(&fieldCursor, file: reader.path, lineNumber: lineNumber)
            let idBytes = try fields.next(&fieldCursor, file: reader.path, lineNumber: lineNumber)
            let languageBytes = try fields.next(
                &fieldCursor,
                file: reader.path,
                lineNumber: lineNumber
            )
            let name = try fields.next(&fieldCursor, file: reader.path, lineNumber: lineNumber)
            let preferred = try fields.next(
                &fieldCursor,
                file: reader.path,
                lineNumber: lineNumber
            )
            let short = try fields.next(&fieldCursor, file: reader.path, lineNumber: lineNumber)
            let colloquial = try fields.next(
                &fieldCursor,
                file: reader.path,
                lineNumber: lineNumber
            )
            let historic = try fields.next(
                &fieldCursor,
                file: reader.path,
                lineNumber: lineNumber
            )

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
            let writer = inputWriter
            try writer.writeRecord(byteCount: AlternateInputLayout.stride) { bytes in
                bytes.writeLittleEndian(initial.idToRow[Int(id)], at: AlternateInputLayout.row)
                bytes.writeLittleEndian(languageID, at: AlternateInputLayout.languageID)
                bytes.writeLittleEndian(isPostcode ? UInt8(1) : UInt8(0), at: AlternateInputLayout.kind)
                bytes.writeLittleEndian(preference, at: AlternateInputLayout.preference)
                bytes.writeLittleEndian(UInt32(name.count), at: AlternateInputLayout.byteCount)
                bytes.writeLittleEndian(UInt64(lineNumber), at: AlternateInputLayout.sourceOrder)
            }
            try writer.write(name)
        }
        _ = try inputWriter.close()
        let sorted = try ExternalSort.sort(
            inputs: [unsorted],
            workspace: workspace,
            label: "alternate",
            headerSize: AlternateInputLayout.stride,
            lengthOffset: AlternateInputLayout.byteCount,
            memoryBytes: options.memoryLimitBytes - initial.managedBytes
        ) { lhs, rhs in
            if lhs.readUInt32(at: AlternateInputLayout.row) != rhs.readUInt32(at: AlternateInputLayout.row) {
                return lhs.readUInt32(at: AlternateInputLayout.row) < rhs.readUInt32(at: AlternateInputLayout.row)
            }
            if lhs[AlternateInputLayout.kind] != rhs[AlternateInputLayout.kind] {
                return lhs[AlternateInputLayout.kind] < rhs[AlternateInputLayout.kind]
            }
            if lhs[AlternateInputLayout.kind] == 0 {
                if lhs.readUInt16(at: AlternateInputLayout.languageID)
                    != rhs.readUInt16(at: AlternateInputLayout.languageID)
                {
                    return lhs.readUInt16(at: AlternateInputLayout.languageID)
                        < rhs.readUInt16(at: AlternateInputLayout.languageID)
                }
                if lhs[AlternateInputLayout.preference] != rhs[AlternateInputLayout.preference] {
                    return lhs[AlternateInputLayout.preference] > rhs[AlternateInputLayout.preference]
                }
            }
            return lhs.readUInt64(at: AlternateInputLayout.sourceOrder)
                < rhs.readUInt64(at: AlternateInputLayout.sourceOrder)
        }
        try fileManager.removeItem(at: unsorted)
        let rows = Int(initial.recordCount)
        var alternateStarts = [UInt32](repeating: 0, count: rows)
        var alternateCounts = [UInt16](repeating: 0, count: rows)
        var postcodeStarts = [UInt32](repeating: 0, count: rows)
        var postcodeCounts = [UInt16](repeating: 0, count: rows)

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

        let sortedReader = try BinaryRecordReader(
            url: sorted,
            headerSize: AlternateInputLayout.stride,
            lengthOffset: AlternateInputLayout.byteCount
        )
        var previousAlternate: UInt64?
        while try sortedReader.withNextRecord({ bytes -> Void in
            let row = Int(bytes.readUInt32(at: AlternateInputLayout.row))
            let language = bytes.readUInt16(at: AlternateInputLayout.languageID)
            let key = UInt64(row) << 16 | UInt64(language)
            if bytes[AlternateInputLayout.kind] == 0 {
                guard previousAlternate != key else { return }
                previousAlternate = key
                guard alternateCounts[row] < UInt16.max else {
                    throw GeoNamesImportError.tooManyValues("alternate names")
                }
                if alternateCounts[row] == 0 { alternateStarts[row] = alternateRecordCount }
                alternateCounts[row] += 1
                let offset = try alternateStrings.currentUInt32Offset()
                try alternateStrings.write(UInt32(bytes.count - AlternateInputLayout.stride))
                try alternateStrings.write(bytes.extracting(AlternateInputLayout.stride...))
                try alternateRecords.writeRecord(byteCount: AlternateNameRecordLayout.stride) { bytes in
                    bytes.writeLittleEndian(language, at: AlternateNameRecordLayout.languageID)
                    bytes.writeLittleEndian(offset, at: AlternateNameRecordLayout.nameOffset)
                }
                alternateRecordCount += 1
            } else {
                guard postcodeCounts[row] < UInt16.max else { throw GeoNamesImportError.tooManyValues("postcodes") }
                if postcodeCounts[row] == 0 { postcodeStarts[row] = postcodeRecordCount }
                postcodeCounts[row] += 1
                let offset = try postcodeStrings.currentUInt32Offset()
                try postcodeStrings.write(UInt32(bytes.count - AlternateInputLayout.stride))
                try postcodeStrings.write(bytes.extracting(AlternateInputLayout.stride...))
                try postcodeOffsets.write(offset)
                postcodeRecordCount += 1
            }
        }) != nil {}
        try fileManager.removeItem(at: sorted)

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
                stride: UInt32(AlternateNameRecordLayout.stride),
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
        let searchCandidates: URL
    }

    private func buildRecords(
        initial: GeoNamesScanSummary,
        alternate: AlternateNamesBuildResult
    ) throws -> RecordBuildOutput {
        let locationWriter = try BufferedBinaryWriter(url: workspace.appendingPathComponent("locations.section"))
        let canonicalStringsURL = workspace.appendingPathComponent("canonical-strings.section")
        let canonicalStrings = try BufferedBinaryWriter(url: canonicalStringsURL)
        let timezones = ByteStringInterner()
        let idToRow = initial.idToRow

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

        let searchWriter = try BufferedBinaryWriter(url: workspace.appendingPathComponent("search-candidates.input"))
        let emptyLanguage = alternate.languages.firstIndex(of: "")
        let iataLanguage = alternate.languages.firstIndex(of: "iata")
        let icaoLanguage = alternate.languages.firstIndex(of: "icao")
        let abbreviationLanguage = alternate.languages.firstIndex(of: "abbr")
        let englishLanguage = alternate.languages.firstIndex(of: "en")
        var administrativeAliases =
            [AdministrativeAliasBuildKey: Set<AdministrativeAliasBuildCandidate>]()

        func insertAdministrativeAlias(
            _ candidate: AdministrativeAliasBuildCandidate,
            kind: AdministrativeAliasKind,
            languageID: UInt16 = 0,
            name: String
        ) {
            let normalized = AdministrativeAreaResolver.normalize(name)
            guard !normalized.isEmpty else {
                return
            }
            administrativeAliases[
                AdministrativeAliasBuildKey(
                    kind: kind,
                    languageID: languageID,
                    name: normalized
                ),
                default: []
            ].insert(candidate)
        }

        func insertAdministrativeAlias(
            _ candidate: AdministrativeAliasBuildCandidate,
            kind: AdministrativeAliasKind,
            languageID: UInt16 = 0,
            bytes: borrowing Span<UInt8>
        ) throws {
            let name = bytes.withUnsafeBufferPointer {
                String(bytes: $0, encoding: .utf8)
            }
            guard let name else {
                throw DatabaseFormatError.invalidSection(
                    .administrativeAliasStrings,
                    "administrative alias is not valid UTF-8"
                )
            }
            insertAdministrativeAlias(
                candidate,
                kind: kind,
                languageID: languageID,
                name: name
            )
        }

        var ignoredFingerprint = XXHash64()
        let reader = try BufferedLineReader(url: paths.geonamesFile)
        var lineNumber = 0
        var row: UInt32 = 0
        try reader.forEachLine(hasher: &ignoredFingerprint) { line in
            lineNumber += 1
            guard !line.isEmpty else {
                return
            }
            let fields = TSVLineScanner(line)
            var fieldCursor = TSVFieldCursor()
            let idBytes = try fields.next(&fieldCursor, file: reader.path, lineNumber: lineNumber)
            let name = try fields.next(&fieldCursor, file: reader.path, lineNumber: lineNumber)
            _ = try fields.next(&fieldCursor, file: reader.path, lineNumber: lineNumber)
            _ = try fields.next(&fieldCursor, file: reader.path, lineNumber: lineNumber)
            let latitudeBytes = try fields.next(
                &fieldCursor,
                file: reader.path,
                lineNumber: lineNumber
            )
            let longitudeBytes = try fields.next(
                &fieldCursor,
                file: reader.path,
                lineNumber: lineNumber
            )
            _ = try fields.next(&fieldCursor, file: reader.path, lineNumber: lineNumber)
            let feature = try fields.next(&fieldCursor, file: reader.path, lineNumber: lineNumber)
            let countryBytes = try fields.next(
                &fieldCursor,
                file: reader.path,
                lineNumber: lineNumber
            )
            _ = try fields.next(&fieldCursor, file: reader.path, lineNumber: lineNumber)
            let admin1 = try fields.next(&fieldCursor, file: reader.path, lineNumber: lineNumber)
            let admin2 = try fields.next(&fieldCursor, file: reader.path, lineNumber: lineNumber)
            let admin3 = try fields.next(&fieldCursor, file: reader.path, lineNumber: lineNumber)
            let admin4 = try fields.next(&fieldCursor, file: reader.path, lineNumber: lineNumber)
            let populationBytes = try fields.next(
                &fieldCursor,
                file: reader.path,
                lineNumber: lineNumber
            )
            let elevationBytes = try fields.next(
                &fieldCursor,
                file: reader.path,
                lineNumber: lineNumber
            )
            let demBytes = try fields.next(&fieldCursor, file: reader.path, lineNumber: lineNumber)
            let timezoneBytes = try fields.next(
                &fieldCursor,
                file: reader.path,
                lineNumber: lineNumber
            )

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
            let admin1ID = initial.administrativeCodes.find(
                level: 0,
                country: country,
                code1: admin1,
                code2: admin2,
                code3: admin3,
                code4: admin4
            )
            let admin2ID = initial.administrativeCodes.find(
                level: 1,
                country: country,
                code1: admin1,
                code2: admin2,
                code3: admin3,
                code4: admin4
            )
            let admin3ID = initial.administrativeCodes.find(
                level: 2,
                country: country,
                code1: admin1,
                code2: admin2,
                code3: admin3,
                code4: admin4
            )
            let admin4ID = initial.administrativeCodes.find(
                level: 3,
                country: country,
                code1: admin1,
                code2: admin2,
                code3: admin3,
                code4: admin4
            )
            let alternateStart = alternate.alternateStarts[Int(row)]
            let alternateCount = alternate.alternateCounts[Int(row)]
            let postcodeStart = alternate.postcodeStarts[Int(row)]
            let postcodeCount = alternate.postcodeCounts[Int(row)]
            let rank = GeoNamesRecordRules.ranking(
                population: population,
                feature: feature,
                hasPostcode: postcodeCount > 0
            )
            let nameOffset = try canonicalStrings.currentUInt32Offset()
            try canonicalStrings.write(UInt32(name.count))
            try canonicalStrings.write(name)

            guard idToRow[Int(id)] == row else {
                throw DatabaseFormatError.invalidSection(.locations, "source IDs changed between passes")
            }
            try locationWriter.writeRecord(byteCount: LocationRecordLayout.stride) { bytes in
                bytes.writeLittleEndian(id, at: LocationRecordLayout.id)
                bytes.writeLittleEndian(latitude.bitPattern, at: LocationRecordLayout.latitude)
                bytes.writeLittleEndian(longitude.bitPattern, at: LocationRecordLayout.longitude)
                bytes.writeLittleEndian(population, at: LocationRecordLayout.population)
                bytes.writeLittleEndian(initial.countries[country] ?? 0, at: LocationRecordLayout.countryID)
                bytes.writeLittleEndian(admin1ID, at: LocationRecordLayout.admin1ID)
                bytes.writeLittleEndian(admin2ID, at: LocationRecordLayout.admin2ID)
                bytes.writeLittleEndian(admin3ID, at: LocationRecordLayout.admin3ID)
                bytes.writeLittleEndian(admin4ID, at: LocationRecordLayout.admin4ID)
                bytes.writeLittleEndian(nameOffset, at: LocationRecordLayout.nameOffset)
                bytes.writeLittleEndian(alternateStart, at: LocationRecordLayout.alternateStart)
                bytes.writeLittleEndian(postcodeStart, at: LocationRecordLayout.postcodeStart)
                bytes.writeLittleEndian(elevation, at: LocationRecordLayout.elevation)
                bytes.writeLittleEndian(timezone, at: LocationRecordLayout.timezone)
                bytes.writeLittleEndian(country, at: LocationRecordLayout.country)
                bytes.writeLittleEndian(alternateCount, at: LocationRecordLayout.alternateCount)
                bytes.writeLittleEndian(postcodeCount, at: LocationRecordLayout.postcodeCount)
                bytes.writeLittleEndian(featureIndex, at: LocationRecordLayout.feature)
            }

            let isCountry = GeoNamesRecordRules.isCountry(
                featureIndex: featureIndex
            )
            if feature.equalsASCII("ADM1") || isCountry, country != 0 {
                let aliasCandidate = AdministrativeAliasBuildCandidate(
                    admin1ID: isCountry ? 0 : id,
                    country: country
                )
                try insertAdministrativeAlias(
                    aliasCandidate,
                    kind: .common,
                    bytes: name
                )
                for alternateIndex in 0..<Int(alternateCount) {
                    let record = (Int(alternateStart) + alternateIndex) * AlternateNameRecordLayout.stride
                    let languageID = alternateRecordBytes.readUInt16(at: record + AlternateNameRecordLayout.languageID)
                    let offset = alternateRecordBytes.readUInt32(at: record + AlternateNameRecordLayout.nameOffset)
                    let alternateName = try stringBytes(
                        in: alternateStringBytes.span,
                        offset: offset,
                        section: .alternateStrings
                    )
                    if languageID == abbreviationLanguage {
                        try insertAdministrativeAlias(
                            aliasCandidate,
                            kind: isCountry ? .common : .abbreviation,
                            bytes: alternateName
                        )
                    } else if languageID == emptyLanguage
                        || languageID == englishLanguage
                    {
                        try insertAdministrativeAlias(
                            aliasCandidate,
                            kind: .common,
                            bytes: alternateName
                        )
                    } else {
                        try insertAdministrativeAlias(
                            aliasCandidate,
                            kind: .localized,
                            languageID: languageID,
                            bytes: alternateName
                        )
                    }
                }
                if isCountry {
                    insertAdministrativeAlias(
                        aliasCandidate,
                        kind: .common,
                        name: GeocodingDatabase.countryString(country)
                    )
                }
            }

            if GeoNamesRecordRules.includeInSearchIndex(featureIndex: featureIndex) {
                try emitSearchCandidate(
                    bytes: name,
                    indexID: 0,
                    country: country,
                    admin1ID: admin1ID,
                    row: row,
                    ranking: rank,
                    writer: searchWriter
                )
                for alternateIndex in 0..<Int(alternateCount) {
                    let record = (Int(alternateStart) + alternateIndex) * AlternateNameRecordLayout.stride
                    let languageID = alternateRecordBytes.readUInt16(at: record + AlternateNameRecordLayout.languageID)
                    let offset = alternateRecordBytes.readUInt32(at: record + AlternateNameRecordLayout.nameOffset)
                    let alternateName = try stringBytes(
                        in: alternateStringBytes.span,
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
                            writer: searchWriter
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
                            writer: searchWriter
                        )
                    }
                }
                for postcodeIndex in 0..<Int(postcodeCount) {
                    let offsetIndex = Int(postcodeStart) + postcodeIndex
                    let offset = postcodeOffsetBytes.readUInt32(at: offsetIndex * 4)
                    let postcode = try stringBytes(
                        in: postcodeStringBytes.span,
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
                        writer: searchWriter
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

        guard ignoredFingerprint.digest() == initial.fingerprint else {
            throw DatabaseFormatError.invalidHeader("GeoNames input changed between build passes")
        }
        var artifacts = [DatabaseSectionArtifact]()
        let locationResult = try locationWriter.close()
        artifacts.append(
            DatabaseSectionArtifact(
                kind: .locations,
                url: locationWriter.url,
                length: locationResult.length,
                count: UInt64(initial.recordCount),
                stride: UInt32(LocationRecordLayout.stride),
                hash: locationResult.hash
            )
        )
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
        artifacts.append(
            contentsOf: try writeAdministrativeAliases(administrativeAliases)
        )
        artifacts.append(try writeDenseIDMap(idToRow))
        _ = try searchWriter.close()
        return RecordBuildOutput(
            artifacts: artifacts,
            timezones: timezones,
            searchCandidates: searchWriter.url
        )
    }

    private func emitSearchCandidate(
        bytes: borrowing Span<UInt8>,
        indexID: UInt16,
        country: UInt16,
        admin1ID: Int32,
        row: UInt32,
        ranking: Float,
        writer: BufferedBinaryWriter
    ) throws {
        let value = bytes.withUnsafeBufferPointer {
            String(bytes: $0, encoding: .utf8)
        }
        guard let value else {
            throw DatabaseFormatError.invalidSection(
                .searchEdgeLabels,
                "search name is not valid UTF-8"
            )
        }
        let normalized = SearchTextNormalizer.foldAndLowercase(value)
        guard
            let characterCount = UInt16(exactly: normalized.count),
            let byteCount = UInt32(exactly: normalized.utf8.count)
        else {
            throw GeoNamesImportError.tooManyValues("characters in a search name")
        }
        try writer.writeRecord(byteCount: SearchCandidateLayout.stride) { bytes in
            bytes.writeLittleEndian(indexID, at: SearchCandidateLayout.indexID)
            bytes.writeLittleEndian(country, at: SearchCandidateLayout.country)
            bytes.writeLittleEndian(UInt32(bitPattern: admin1ID), at: SearchCandidateLayout.admin1ID)
            bytes.writeLittleEndian(row, at: SearchCandidateLayout.row)
            bytes.writeLittleEndian(ranking.bitPattern, at: SearchCandidateLayout.rank)
            bytes.writeLittleEndian(characterCount, at: SearchCandidateLayout.characterCount)
            bytes.writeLittleEndian(byteCount, at: SearchCandidateLayout.byteCount)
        }
        let normalizedBytes = Array(normalized.utf8)
        try normalizedBytes.withUnsafeBytes {
            try writer.write($0)
        }
    }

    @_lifetime(copy pool)
    private func stringBytes(
        in pool: borrowing Span<UInt8>,
        offset: UInt32,
        section: DatabaseSectionKind
    ) throws -> Span<UInt8> {
        let position = Int(offset)
        guard position + 4 <= pool.count else {
            throw DatabaseFormatError.invalidStringOffset(section: section, offset: offset)
        }
        let length = Int(pool.readUInt32(at: position))
        guard length <= pool.count - position - 4 else {
            throw DatabaseFormatError.invalidStringOffset(section: section, offset: offset)
        }
        return pool.extracting(position + 4..<position + 4 + length)
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

    private func writeAdministrativeAliases(
        _ aliases: [AdministrativeAliasBuildKey: Set<AdministrativeAliasBuildCandidate>]
    ) throws -> [DatabaseSectionArtifact] {
        func namePrecedes(_ lhs: String, _ rhs: String) -> Bool {
            let left = Array(lhs.utf8)
            let right = Array(rhs.utf8)
            return left.lexicographicallyPrecedes(right)
        }
        let keys = aliases.keys.sorted {
            if $0.kind.rawValue != $1.kind.rawValue {
                return $0.kind.rawValue < $1.kind.rawValue
            }
            if $0.languageID != $1.languageID {
                return $0.languageID < $1.languageID
            }
            return namePrecedes($0.name, $1.name)
        }

        let recordsURL = workspace.appendingPathComponent(
            "administrative-alias-records.section"
        )
        let stringsURL = workspace.appendingPathComponent(
            "administrative-alias-strings.section"
        )
        let candidatesURL = workspace.appendingPathComponent(
            "administrative-alias-candidates.section"
        )
        let records = try BufferedBinaryWriter(url: recordsURL)
        let strings = try BufferedBinaryWriter(url: stringsURL)
        let candidates = try BufferedBinaryWriter(url: candidatesURL)
        var candidateCount: UInt32 = 0

        for key in keys {
            let nameOffset = try strings.writeLengthPrefixed(key.name)
            let values = aliases[key]!.sorted {
                if $0.admin1ID != $1.admin1ID {
                    return $0.admin1ID < $1.admin1ID
                }
                return $0.country < $1.country
            }
            guard let compactCount = UInt16(exactly: values.count) else {
                throw GeoNamesImportError.tooManyValues(
                    "administrative-area alias candidates"
                )
            }
            try records.writeRecord(byteCount: AdministrativeAliasRecordLayout.stride) { bytes in
                bytes.writeLittleEndian(key.kind.rawValue, at: AdministrativeAliasRecordLayout.kind)
                bytes.writeLittleEndian(key.languageID, at: AdministrativeAliasRecordLayout.languageID)
                bytes.writeLittleEndian(nameOffset, at: AdministrativeAliasRecordLayout.nameOffset)
                bytes.writeLittleEndian(candidateCount, at: AdministrativeAliasRecordLayout.candidateStart)
                bytes.writeLittleEndian(compactCount, at: AdministrativeAliasRecordLayout.candidateCount)
            }
            for value in values {
                try candidates.writeRecord(byteCount: AdministrativeAliasCandidateLayout.stride) { bytes in
                    bytes.writeLittleEndian(value.admin1ID, at: AdministrativeAliasCandidateLayout.admin1ID)
                    bytes.writeLittleEndian(value.country, at: AdministrativeAliasCandidateLayout.country)
                }
                candidateCount += 1
            }
        }

        let recordsResult = try records.close()
        let stringsResult = try strings.close()
        let candidatesResult = try candidates.close()
        return [
            DatabaseSectionArtifact(
                kind: .administrativeAliasRecords,
                url: recordsURL,
                length: recordsResult.length,
                count: UInt64(keys.count),
                stride: UInt32(AdministrativeAliasIndexLayout.recordStride),
                hash: recordsResult.hash
            ),
            DatabaseSectionArtifact(
                kind: .administrativeAliasStrings,
                url: stringsURL,
                length: stringsResult.length,
                count: stringsResult.length,
                stride: 1,
                hash: stringsResult.hash
            ),
            DatabaseSectionArtifact(
                kind: .administrativeAliasCandidates,
                url: candidatesURL,
                length: candidatesResult.length,
                count: UInt64(candidateCount),
                stride: UInt32(AdministrativeAliasIndexLayout.candidateStride),
                hash: candidatesResult.hash
            ),
        ]
    }

    private func publish(output: URL) throws {
        let destination = paths.databaseFile.path
        if !options.force {
            // Hard-link publication is atomic and fails if the destination exists.
            guard link(output.path, destination) == 0 else {
                throw DatabaseBuildIOError.write(
                    path: destination,
                    message: "Publication failed (use --force to replace): \(String(cString: strerror(errno)))"
                )
            }
            try fileManager.removeItem(at: output)
            try synchronizeDirectory()
            return
        }
        guard rename(output.path, destination) == 0 else {
            throw DatabaseBuildIOError.write(
                path: destination,
                message: String(cString: strerror(errno))
            )
        }
        try synchronizeDirectory()
    }

    private func synchronizeDirectory() throws {
        let path = paths.databaseFile.deletingLastPathComponent().path
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else {
            throw DatabaseBuildIOError.open(path: path, message: String(cString: strerror(errno)))
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw DatabaseBuildIOError.write(path: path, message: String(cString: strerror(errno)))
        }
    }

    private func writeContainer(
        output: URL,
        artifacts: [DatabaseSectionArtifact],
        recordCount: UInt32,
        maximumID: UInt32,
        geonamesFingerprint: UInt64,
        alternateNamesFingerprint: UInt64
    ) throws {
        guard fileManager.createFile(atPath: output.path, contents: nil) else {
            throw DatabaseBuildIOError.open(path: output.path, message: "createFile failed")
        }
        let handle = try FileHandle(forWritingTo: output)
        try handle.write(contentsOf: Data(repeating: 0, count: DatabaseFileHeader.encodedSize))
        var currentOffset = UInt64(DatabaseFileHeader.encodedSize)
        var descriptors = [DatabaseSectionDescriptor]()

        for artifact in artifacts.sorted(by: { $0.kind.rawValue < $1.kind.rawValue }) {
            let alignmentMask = DatabaseFileHeader.sectionAlignment - 1
            let aligned = (currentOffset + alignmentMask) & ~alignmentMask
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
    }
}
