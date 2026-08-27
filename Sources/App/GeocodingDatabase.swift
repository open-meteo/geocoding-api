import Foundation
import Vapor

final class GeocodingDatabase: @unchecked Sendable {
    static let databaseFile = GeocodingDatabaseBuilder.databaseFile

    let mappedFile: MappedFile
    let header: DatabaseFileHeader
    let languages: [String]
    let timezones: [String]
    let features: [String]
    let languageIDs: [String: UInt16]

    private let idToRow: MappedDatabaseSection
    private let rowToID: MappedDatabaseSection
    private let latitudeValues: MappedDatabaseSection
    private let longitudeValues: MappedDatabaseSection
    private let rankingValues: MappedDatabaseSection
    private let elevationValues: MappedDatabaseSection
    private let featureValues: MappedDatabaseSection
    private let countryValues: MappedDatabaseSection
    private let countryIDValues: MappedDatabaseSection
    private let admin1Values: MappedDatabaseSection
    private let admin2Values: MappedDatabaseSection
    private let admin3Values: MappedDatabaseSection
    private let admin4Values: MappedDatabaseSection
    private let timezoneValues: MappedDatabaseSection
    private let populationValues: MappedDatabaseSection
    private let nameOffsets: MappedDatabaseSection
    private let alternateStarts: MappedDatabaseSection
    private let alternateCounts: MappedDatabaseSection
    private let postcodeStarts: MappedDatabaseSection
    private let postcodeCounts: MappedDatabaseSection

    private let canonicalStrings: UnsafeRawBufferPointer
    private let alternateRecords: UnsafeRawBufferPointer
    private let alternateStrings: UnsafeRawBufferPointer
    private let postcodeOffsets: MappedDatabaseSection
    private let postcodeStrings: UnsafeRawBufferPointer
    private let rawSections: [DatabaseSectionKind: UnsafeRawBufferPointer]

    let searchIndex: PackedRadixSearchIndex

    init(url: URL = GeocodingDatabase.databaseFile) throws {
        let mappedFile = try MappedFile(url: url)
        let header = try DatabaseFileHeader(mappedFile: mappedFile)
        self.mappedFile = mappedFile
        self.header = header

        func fixed(
            _ kind: DatabaseSectionKind,
            stride: UInt32,
            count: UInt64? = nil
        ) throws -> MappedDatabaseSection {
            guard let descriptor = header.sections[kind] else {
                throw DatabaseFormatError.missingSection(kind)
            }
            guard descriptor.stride == stride else {
                throw DatabaseFormatError.invalidSection(
                    kind,
                    "expected stride \(stride), found \(descriptor.stride)"
                )
            }
            if let count, descriptor.count != count {
                throw DatabaseFormatError.invalidSection(
                    kind,
                    "expected \(count) values, found \(descriptor.count)"
                )
            }
            guard
                let compactCount = Int(exactly: descriptor.count),
                let compactStride = Int(exactly: descriptor.stride)
            else {
                throw DatabaseFormatError.invalidSection(kind, "section is too large")
            }
            return MappedDatabaseSection(
                owner: mappedFile,
                kind: kind,
                bytes: try mappedFile.bytes(
                    offset: descriptor.offset,
                    length: descriptor.length
                ),
                count: compactCount,
                stride: compactStride
            )
        }

        func raw(_ kind: DatabaseSectionKind) throws -> UnsafeRawBufferPointer {
            guard let descriptor = header.sections[kind] else {
                throw DatabaseFormatError.missingSection(kind)
            }
            return try mappedFile.bytes(
                offset: descriptor.offset,
                length: descriptor.length
            )
        }

        let records = UInt64(header.recordCount)
        idToRow = try fixed(
            .idToRow,
            stride: 4,
            count: UInt64(header.maximumGeonameID) + 1
        )
        rowToID = try fixed(.rowToID, stride: 4, count: records)
        latitudeValues = try fixed(.latitude, stride: 4, count: records)
        longitudeValues = try fixed(.longitude, stride: 4, count: records)
        rankingValues = try fixed(.ranking, stride: 4, count: records)
        elevationValues = try fixed(.elevation, stride: 2, count: records)
        featureValues = try fixed(.feature, stride: 1, count: records)
        countryValues = try fixed(.countryISO2, stride: 2, count: records)
        countryIDValues = try fixed(.countryID, stride: 4, count: records)
        admin1Values = try fixed(.admin1ID, stride: 4, count: records)
        admin2Values = try fixed(.admin2ID, stride: 4, count: records)
        admin3Values = try fixed(.admin3ID, stride: 4, count: records)
        admin4Values = try fixed(.admin4ID, stride: 4, count: records)
        timezoneValues = try fixed(.timezoneIndex, stride: 2, count: records)
        populationValues = try fixed(.population, stride: 4, count: records)
        nameOffsets = try fixed(.nameOffset, stride: 4, count: records)
        alternateStarts = try fixed(.alternateStart, stride: 4, count: records)
        alternateCounts = try fixed(.alternateCount, stride: 2, count: records)
        postcodeStarts = try fixed(.postcodeStart, stride: 4, count: records)
        postcodeCounts = try fixed(.postcodeCount, stride: 2, count: records)

        canonicalStrings = try raw(.canonicalStrings)
        alternateRecords = try raw(.alternateRecords)
        alternateStrings = try raw(.alternateStrings)
        postcodeOffsets = try fixed(.postcodeOffsets, stride: 4)
        postcodeStrings = try raw(.postcodeStrings)

        features = try Self.decodeStringTable(
            bytes: raw(.featureStrings),
            count: header.sections[.featureStrings]!.count,
            kind: .featureStrings
        )
        timezones = try Self.decodeStringTable(
            bytes: raw(.timezoneStrings),
            count: header.sections[.timezoneStrings]!.count,
            kind: .timezoneStrings
        )
        languages = try Self.decodeStringTable(
            bytes: raw(.languageStrings),
            count: header.sections[.languageStrings]!.count,
            kind: .languageStrings
        )
        languageIDs = Dictionary(
            uniqueKeysWithValues: languages.enumerated().map {
                ($0.element, UInt16($0.offset))
            }
        )

        let searchRoots = try fixed(
            .searchRoots,
            stride: UInt32(PackedRadixIndexLayout.rootStride)
        )
        let searchNodes = try fixed(
            .searchNodes,
            stride: UInt32(PackedRadixIndexLayout.nodeStride)
        )
        let searchEdges = try fixed(
            .searchEdges,
            stride: UInt32(PackedRadixIndexLayout.edgeStride)
        )
        let searchLabels = try fixed(.searchEdgeLabels, stride: 1)
        let searchMetadata = try fixed(
            .searchNameMetadata,
            stride: UInt32(PackedRadixIndexLayout.nameMetadataStride)
        )
        let searchPostings = try fixed(
            .searchPostings,
            stride: UInt32(PackedRadixIndexLayout.postingStride)
        )
        let searchGlobalTrees = try fixed(
            .searchGlobalTrees,
            stride: UInt32(PackedRadixIndexLayout.treeNodeStride)
        )
        let searchCountryBuckets = try fixed(
            .searchCountryBuckets,
            stride: UInt32(PackedRadixIndexLayout.areaBucketStride)
        )
        let searchCountryEntries = try fixed(
            .searchCountryEntries,
            stride: UInt32(PackedRadixIndexLayout.areaEntryStride)
        )
        let searchCountryTrees = try fixed(
            .searchCountryTrees,
            stride: UInt32(PackedRadixIndexLayout.treeNodeStride)
        )
        let searchAdminBuckets = try fixed(
            .searchAdminBuckets,
            stride: UInt32(PackedRadixIndexLayout.areaBucketStride)
        )
        let searchAdminEntries = try fixed(
            .searchAdminEntries,
            stride: UInt32(PackedRadixIndexLayout.areaEntryStride)
        )
        let searchAdminTrees = try fixed(
            .searchAdminTrees,
            stride: UInt32(PackedRadixIndexLayout.treeNodeStride)
        )
        let administrativeAliasRecords = try fixed(
            .administrativeAliasRecords,
            stride: UInt32(AdministrativeAliasIndexLayout.recordStride)
        )
        let administrativeAliasStrings = try fixed(
            .administrativeAliasStrings,
            stride: 1
        )
        let administrativeAliasCandidates = try fixed(
            .administrativeAliasCandidates,
            stride: UInt32(AdministrativeAliasIndexLayout.candidateStride)
        )
        try Self.validateSearchIndex(
            roots: searchRoots,
            nodes: searchNodes,
            edges: searchEdges,
            labels: searchLabels,
            metadata: searchMetadata,
            postings: searchPostings,
            globalTrees: searchGlobalTrees,
            countryBuckets: searchCountryBuckets,
            countryEntries: searchCountryEntries,
            countryTrees: searchCountryTrees,
            adminBuckets: searchAdminBuckets,
            adminEntries: searchAdminEntries,
            adminTrees: searchAdminTrees,
            recordCount: Int(header.recordCount)
        )
        try Self.validateAdministrativeAliases(
            records: administrativeAliasRecords,
            strings: administrativeAliasStrings,
            candidates: administrativeAliasCandidates,
            languageCount: languages.count
        )
        let rawSections: [DatabaseSectionKind: UnsafeRawBufferPointer] = [
            .rowToID: rowToID.bytes,
            .searchRoots: searchRoots.bytes,
            .searchNodes: searchNodes.bytes,
            .searchEdges: searchEdges.bytes,
            .searchEdgeLabels: searchLabels.bytes,
            .searchNameMetadata: searchMetadata.bytes,
            .searchPostings: searchPostings.bytes,
            .searchGlobalTrees: searchGlobalTrees.bytes,
            .searchCountryBuckets: searchCountryBuckets.bytes,
            .searchCountryEntries: searchCountryEntries.bytes,
            .searchCountryTrees: searchCountryTrees.bytes,
            .searchAdminBuckets: searchAdminBuckets.bytes,
            .searchAdminEntries: searchAdminEntries.bytes,
            .searchAdminTrees: searchAdminTrees.bytes,
            .administrativeAliasRecords: administrativeAliasRecords.bytes,
            .administrativeAliasStrings: administrativeAliasStrings.bytes,
            .administrativeAliasCandidates: administrativeAliasCandidates.bytes,
        ]
        self.rawSections = rawSections

        func validateStringOffset(
            pool: UnsafeRawBufferPointer,
            offset: UInt32,
            section: DatabaseSectionKind
        ) throws {
            let position = Int(offset)
            guard position <= pool.count, pool.count - position >= 4 else {
                throw DatabaseFormatError.invalidStringOffset(
                    section: section,
                    offset: offset
                )
            }
            let length = Int(pool.readUInt32(at: position))
            guard length <= pool.count - position - 4 else {
                throw DatabaseFormatError.invalidStringOffset(
                    section: section,
                    offset: offset
                )
            }
        }

        for row in 0..<Int(header.recordCount) {
            let id = rowToID.uint32(at: row)
            guard
                id <= header.maximumGeonameID,
                idToRow.uint32(at: Int(id)) == UInt32(row)
            else {
                throw DatabaseFormatError.invalidSection(
                    .rowToID,
                    "row \(row) is inconsistent with the dense ID map"
                )
            }
            guard
                latitudeValues.float32(at: row).isFinite,
                longitudeValues.float32(at: row).isFinite,
                rankingValues.float32(at: row).isFinite
            else {
                throw DatabaseFormatError.invalidSection(
                    .ranking,
                    "row \(row) contains a non-finite coordinate or rank"
                )
            }
            guard Int(featureValues.uint8(at: row)) < features.count else {
                throw DatabaseFormatError.invalidSection(
                    .feature,
                    "row \(row) has an invalid feature index"
                )
            }
            guard Int(timezoneValues.uint16(at: row)) < timezones.count else {
                throw DatabaseFormatError.invalidSection(
                    .timezoneIndex,
                    "row \(row) has an invalid timezone index"
                )
            }
            try validateStringOffset(
                pool: canonicalStrings,
                offset: nameOffsets.uint32(at: row),
                section: .canonicalStrings
            )

            let alternateStart = Int(alternateStarts.uint32(at: row))
            let alternateCount = Int(alternateCounts.uint16(at: row))
            guard
                alternateStart <= alternateRecords.count / 6,
                alternateCount <= alternateRecords.count / 6 - alternateStart
            else {
                throw DatabaseFormatError.invalidSection(
                    .alternateRecords,
                    "row \(row) has an invalid alternate-name range"
                )
            }
            var previousLanguage: UInt16?
            for index in 0..<alternateCount {
                let offset = (alternateStart + index) * 6
                let language = alternateRecords.readUInt16(at: offset)
                guard
                    Int(language) < languages.count,
                    previousLanguage == nil || previousLanguage! < language
                else {
                    throw DatabaseFormatError.invalidSection(
                        .alternateRecords,
                        "row \(row) has invalid or unordered language IDs"
                    )
                }
                try validateStringOffset(
                    pool: alternateStrings,
                    offset: alternateRecords.readUInt32(at: offset + 2),
                    section: .alternateStrings
                )
                previousLanguage = language
            }

            let postcodeStart = Int(postcodeStarts.uint32(at: row))
            let postcodeCount = Int(postcodeCounts.uint16(at: row))
            guard
                postcodeStart <= postcodeOffsets.count,
                postcodeCount <= postcodeOffsets.count - postcodeStart
            else {
                throw DatabaseFormatError.invalidSection(
                    .postcodeOffsets,
                    "row \(row) has an invalid postcode range"
                )
            }
            for index in 0..<postcodeCount {
                try validateStringOffset(
                    pool: postcodeStrings,
                    offset: postcodeOffsets.uint32(at: postcodeStart + index),
                    section: .postcodeStrings
                )
            }
        }
        searchIndex = PackedRadixSearchIndex(
            mappedFile: mappedFile,
            header: header,
            sections: rawSections
        )
        mappedFile.optimizeForRandomAccess()
    }

    static func loadOrCreate(
        logger: Logger,
        options: DatabaseBuildOptions = .init()
    ) async throws -> GeocodingDatabase {
        if !FileManager.default.fileExists(atPath: databaseFile.path) {
            guard
                FileManager.default.fileExists(
                    atPath: GeocodingDatabaseBuilder.geonamesFile.path
                ),
                FileManager.default.fileExists(
                    atPath: GeocodingDatabaseBuilder.alternateNamesFile.path
                )
            else {
                throw Abort(
                    .internalServerError,
                    reason:
                        "database-v2.bin is missing. Download allCountries.txt and "
                        + "alternateNamesV2.txt, then run `geocoding-api build-database`."
                )
            }
            try await GeocodingDatabaseBuilder(
                logger: logger,
                options: options
            ).build()
        }
        do {
            return try GeocodingDatabase()
        } catch {
            logger.error("Could not load database-v2.bin: \(error)")
            guard
                FileManager.default.fileExists(
                    atPath: GeocodingDatabaseBuilder.geonamesFile.path
                ),
                FileManager.default.fileExists(
                    atPath: GeocodingDatabaseBuilder.alternateNamesFile.path
                )
            else {
                throw error
            }
            try await GeocodingDatabaseBuilder(
                logger: logger,
                options: DatabaseBuildOptions(
                    memoryLimitBytes: options.memoryLimitBytes,
                    force: true
                )
            ).build()
            return try GeocodingDatabase()
        }
    }

    var recordCount: Int {
        return Int(header.recordCount)
    }

    func rawSection(_ kind: DatabaseSectionKind) -> UnsafeRawBufferPointer {
        return rawSections[kind]!
    }

    func sectionDescriptor(_ kind: DatabaseSectionKind) -> DatabaseSectionDescriptor {
        return header.sections[kind]!
    }

    func row(for id: Int32) -> Int? {
        guard id >= 0, UInt32(id) <= header.maximumGeonameID else {
            return nil
        }
        let row = idToRow.uint32(at: Int(id))
        guard row != UInt32.max, row < header.recordCount else {
            return nil
        }
        return Int(row)
    }

    func id(row: Int) -> Int32 {
        return Int32(bitPattern: rowToID.uint32(at: row))
    }

    func latitude(row: Int) -> Float {
        return latitudeValues.float32(at: row)
    }

    func longitude(row: Int) -> Float {
        return longitudeValues.float32(at: row)
    }

    func ranking(row: Int) -> Float {
        return rankingValues.float32(at: row)
    }

    func featureIndex(row: Int) -> UInt8 {
        return featureValues.uint8(at: row)
    }

    func feature(row: Int) -> String {
        return features[Int(featureIndex(row: row))]
    }

    func countryISO2Value(row: Int) -> UInt16 {
        return countryValues.uint16(at: row)
    }

    func countryISO2(row: Int) -> String {
        return Self.countryString(countryISO2Value(row: row))
    }

    func countryID(row: Int) -> Int32 {
        return countryIDValues.int32(at: row)
    }

    func admin1ID(row: Int) -> Int32 {
        return admin1Values.int32(at: row)
    }

    func admin2ID(row: Int) -> Int32 {
        return admin2Values.int32(at: row)
    }

    func admin3ID(row: Int) -> Int32 {
        return admin3Values.int32(at: row)
    }

    func admin4ID(row: Int) -> Int32 {
        return admin4Values.int32(at: row)
    }

    func population(row: Int) -> UInt32 {
        return populationValues.uint32(at: row)
    }

    func name(row: Int, languageID: UInt16) throws -> String {
        let start = Int(alternateStarts.uint32(at: row))
        let count = Int(alternateCounts.uint16(at: row))
        guard start <= alternateRecords.count / 6, count <= alternateRecords.count / 6 - start
        else {
            throw DatabaseFormatError.invalidSection(
                .alternateRecords,
                "row \(row) alternate range is invalid"
            )
        }
        var low = 0
        var high = count
        while low < high {
            let middle = low + (high - low) / 2
            let record = (start + middle) * 6
            if alternateRecords.readUInt16(at: record) < languageID {
                low = middle + 1
            } else {
                high = middle
            }
        }
        if low < count {
            let record = (start + low) * 6
            if alternateRecords.readUInt16(at: record) == languageID {
                return try string(
                    pool: alternateStrings,
                    offset: alternateRecords.readUInt32(at: record + 2),
                    section: .alternateStrings
                )
            }
        }
        return try string(
            pool: canonicalStrings,
            offset: nameOffsets.uint32(at: row),
            section: .canonicalStrings
        )
    }

    func response(
        id: Int32,
        languageID: UInt16
    ) throws -> GeocodingApi.Geoname? {
        guard let row = row(for: id) else {
            return nil
        }
        var output = GeocodingApi.Geoname()
        output.id = id
        output.name = try name(row: row, languageID: languageID)
        output.latitude = latitude(row: row)
        output.longitude = longitude(row: row)
        output.elevation = Float(elevationValues.int16(at: row))
        output.countryCode = countryISO2(row: row)
        output.countryID = countryID(row: row)
        output.country = try referencedName(
            id: output.countryID,
            languageID: languageID
        )
        output.featureCode = feature(row: row)
        output.admin1ID = admin1ID(row: row)
        output.admin2ID = admin2ID(row: row)
        output.admin3ID = admin3ID(row: row)
        output.admin4ID = admin4ID(row: row)
        output.admin1 = try referencedName(id: output.admin1ID, languageID: languageID)
        output.admin2 = try referencedName(id: output.admin2ID, languageID: languageID)
        output.admin3 = try referencedName(id: output.admin3ID, languageID: languageID)
        output.admin4 = try referencedName(id: output.admin4ID, languageID: languageID)
        output.population = population(row: row)
        output.timezone = timezones[Int(timezoneValues.uint16(at: row))]

        let postcodeStart = Int(postcodeStarts.uint32(at: row))
        let postcodeCount = Int(postcodeCounts.uint16(at: row))
        guard
            postcodeStart <= postcodeOffsets.count,
            postcodeCount <= postcodeOffsets.count - postcodeStart
        else {
            throw DatabaseFormatError.invalidSection(
                .postcodeOffsets,
                "row \(row) postcode range is invalid"
            )
        }
        output.postcodes.reserveCapacity(postcodeCount)
        for index in 0..<postcodeCount {
            output.postcodes.append(
                try string(
                    pool: postcodeStrings,
                    offset: postcodeOffsets.uint32(at: postcodeStart + index),
                    section: .postcodeStrings
                )
            )
        }
        return output
    }

    private func referencedName(
        id: Int32,
        languageID: UInt16
    ) throws -> String {
        guard let row = row(for: id) else {
            return ""
        }
        return try name(row: row, languageID: languageID)
    }

    private func string(
        pool: UnsafeRawBufferPointer,
        offset: UInt32,
        section: DatabaseSectionKind
    ) throws -> String {
        let position = Int(offset)
        guard position + 4 <= pool.count else {
            throw DatabaseFormatError.invalidStringOffset(section: section, offset: offset)
        }
        let length = Int(pool.readUInt32(at: position))
        guard length <= pool.count - position - 4 else {
            throw DatabaseFormatError.invalidStringOffset(section: section, offset: offset)
        }
        guard
            let value = String(
                bytes: pool[position + 4..<position + 4 + length],
                encoding: .utf8
            )
        else {
            throw DatabaseFormatError.invalidSection(section, "string is not valid UTF-8")
        }
        return value
    }

    private static func decodeStringTable(
        bytes: UnsafeRawBufferPointer,
        count: UInt64,
        kind: DatabaseSectionKind
    ) throws -> [String] {
        guard let expectedCount = Int(exactly: count) else {
            throw DatabaseFormatError.invalidSection(kind, "table is too large")
        }
        var result = [String]()
        result.reserveCapacity(expectedCount)
        var offset = 0
        while result.count < expectedCount {
            guard offset + 4 <= bytes.count else {
                throw DatabaseFormatError.invalidSection(kind, "truncated string table")
            }
            let length = Int(bytes.readUInt32(at: offset))
            offset += 4
            guard length <= bytes.count - offset else {
                throw DatabaseFormatError.invalidSection(kind, "string exceeds table")
            }
            guard
                let value = String(
                    bytes: bytes[offset..<offset + length],
                    encoding: .utf8
                )
            else {
                throw DatabaseFormatError.invalidSection(kind, "invalid UTF-8")
            }
            result.append(value)
            offset += length
        }
        guard offset == bytes.count else {
            throw DatabaseFormatError.invalidSection(kind, "trailing string table data")
        }
        return result
    }

    private static func validateSearchIndex(
        roots: MappedDatabaseSection,
        nodes: MappedDatabaseSection,
        edges: MappedDatabaseSection,
        labels: MappedDatabaseSection,
        metadata: MappedDatabaseSection,
        postings: MappedDatabaseSection,
        globalTrees: MappedDatabaseSection,
        countryBuckets: MappedDatabaseSection,
        countryEntries: MappedDatabaseSection,
        countryTrees: MappedDatabaseSection,
        adminBuckets: MappedDatabaseSection,
        adminEntries: MappedDatabaseSection,
        adminTrees: MappedDatabaseSection,
        recordCount: Int
    ) throws {
        var namesByIndex = [UInt16: UInt32]()
        var rootDefinitions = [(node: UInt32, nameCount: UInt32)]()
        var previousIndex: UInt16?
        for rootIndex in 0..<roots.count {
            let offset = rootIndex * roots.stride
            let indexID = roots.bytes.readUInt16(at: offset)
            let rootNode = Int(roots.bytes.readUInt32(at: offset + 4))
            let nameBase = Int(roots.bytes.readUInt32(at: offset + 8))
            let nameCount = Int(roots.bytes.readUInt32(at: offset + 12))
            let treeStart = Int(roots.bytes.readUInt32(at: offset + 16))
            let leafBase = Int(roots.bytes.readUInt32(at: offset + 20))
            guard
                previousIndex == nil || previousIndex! < indexID,
                rootNode < nodes.count,
                nameBase <= metadata.count,
                nameCount <= metadata.count - nameBase
            else {
                throw DatabaseFormatError.invalidSection(
                    .searchRoots,
                    "root \(rootIndex) has invalid ordering or ranges"
                )
            }
            let blockCount =
                (nameCount + PackedRadixIndexLayout.namesPerLeaf - 1)
                / PackedRadixIndexLayout.namesPerLeaf
            guard
                leafBase > 0,
                leafBase & (leafBase - 1) == 0,
                leafBase >= blockCount,
                treeStart <= globalTrees.count,
                leafBase <= (globalTrees.count - treeStart) / 2
            else {
                throw DatabaseFormatError.invalidSection(
                    .searchRoots,
                    "root \(rootIndex) has an invalid segment tree"
                )
            }
            namesByIndex[indexID] = UInt32(nameCount)
            rootDefinitions.append(
                (
                    node: UInt32(rootNode),
                    nameCount: UInt32(nameCount)
                )
            )
            previousIndex = indexID
        }

        for nodeIndex in 0..<nodes.count {
            let offset = nodeIndex * nodes.stride
            let firstEdge = Int(nodes.bytes.readUInt32(at: offset))
            let edgeCount = Int(nodes.bytes.readUInt16(at: offset + 4))
            guard
                firstEdge <= edges.count,
                edgeCount <= edges.count - firstEdge,
                nodes.bytes.readUInt32(at: offset + 12) > 0
            else {
                throw DatabaseFormatError.invalidSection(
                    .searchNodes,
                    "node \(nodeIndex) has invalid edge or subtree ranges"
                )
            }
        }

        for edgeIndex in 0..<edges.count {
            let offset = edgeIndex * edges.stride
            let encodedChild = edges.bytes.readUInt32(at: offset)
            let isLeaf = encodedChild & 0x8000_0000 != 0
            let child = Int(encodedChild & 0x7fff_ffff)
            let labelOffset = Int(edges.bytes.readUInt32(at: offset + 4))
            let labelLength = Int(edges.bytes.readUInt16(at: offset + 8))
            guard
                isLeaf || child < nodes.count,
                labelLength > 0,
                labelOffset <= labels.count,
                labelLength <= labels.count - labelOffset,
                labels.bytes[labelOffset] == edges.bytes[offset + 10]
            else {
                throw DatabaseFormatError.invalidSection(
                    .searchEdges,
                    "edge \(edgeIndex) has invalid child or label ranges"
                )
            }
        }

        var visitedNodes = DynamicBitSet()
        var visitedNodeCount = 0
        for root in rootDefinitions {
            var pending = [root.node]
            while let node = pending.popLast() {
                guard !visitedNodes.contains(node) else {
                    throw DatabaseFormatError.invalidSection(
                        .searchNodes,
                        "radix graph contains a cycle or shared node"
                    )
                }
                visitedNodes.insert(node)
                visitedNodeCount += 1
                let nodeOffset = Int(node) * nodes.stride
                let first = nodes.bytes.readUInt32(at: nodeOffset + 8)
                let count = nodes.bytes.readUInt32(at: nodeOffset + 12)
                guard first < root.nameCount, count <= root.nameCount - first else {
                    throw DatabaseFormatError.invalidSection(
                        .searchNodes,
                        "radix subtree ordinal range is invalid"
                    )
                }
                let firstEdge = Int(nodes.bytes.readUInt32(at: nodeOffset))
                let edgeCount = Int(nodes.bytes.readUInt16(at: nodeOffset + 4))
                var previousFirstByte: UInt8?
                for edgeIndex in firstEdge..<firstEdge + edgeCount {
                    let edgeOffset = edgeIndex * edges.stride
                    let firstByte = edges.bytes[edgeOffset + 10]
                    guard previousFirstByte == nil || previousFirstByte! < firstByte else {
                        throw DatabaseFormatError.invalidSection(
                            .searchEdges,
                            "radix node edges are not strictly ordered"
                        )
                    }
                    previousFirstByte = firstByte
                    let encodedChild = edges.bytes.readUInt32(at: edgeOffset)
                    let child = encodedChild & 0x7fff_ffff
                    if encodedChild & 0x8000_0000 == 0 {
                        pending.append(child)
                    } else if child >= root.nameCount {
                        throw DatabaseFormatError.invalidSection(
                            .searchEdges,
                            "leaf ordinal is outside its search index"
                        )
                    }
                }
            }
        }
        guard visitedNodeCount == nodes.count else {
            throw DatabaseFormatError.invalidSection(
                .searchNodes,
                "radix graph contains unreachable nodes"
            )
        }

        for nameIndex in 0..<metadata.count {
            let offset = nameIndex * metadata.stride
            let start = Int(metadata.bytes.readUInt32(at: offset))
            let count = Int(metadata.bytes.readUInt32(at: offset + 4))
            guard start <= postings.count, count <= postings.count - start else {
                throw DatabaseFormatError.invalidSection(
                    .searchNameMetadata,
                    "name \(nameIndex) has an invalid posting range"
                )
            }
            var previousRank = Float.infinity
            var previousRow: UInt32?
            for postingIndex in start..<start + count {
                let postingOffset = postingIndex * postings.stride
                let row = postings.bytes.readUInt32(at: postingOffset)
                let rank = Float(
                    bitPattern: postings.bytes.readUInt32(
                        at: postingOffset + 4
                    )
                )
                guard
                    row < UInt32(recordCount),
                    rank.isFinite,
                    rank <= previousRank,
                    rank < previousRank || previousRow == nil || previousRow! < row
                else {
                    throw DatabaseFormatError.invalidSection(
                        .searchPostings,
                        "posting \(postingIndex) has an invalid row or ordering"
                    )
                }
                previousRank = rank
                previousRow = row
            }
        }

        try validateAreaBuckets(
            buckets: countryBuckets,
            entries: countryEntries,
            trees: countryTrees,
            namesByIndex: namesByIndex,
            kind: .searchCountryBuckets
        )
        try validateAreaBuckets(
            buckets: adminBuckets,
            entries: adminEntries,
            trees: adminTrees,
            namesByIndex: namesByIndex,
            kind: .searchAdminBuckets
        )
    }

    private static func validateAreaBuckets(
        buckets: MappedDatabaseSection,
        entries: MappedDatabaseSection,
        trees: MappedDatabaseSection,
        namesByIndex: [UInt16: UInt32],
        kind: DatabaseSectionKind
    ) throws {
        var previousKey: (UInt16, UInt32)?
        for bucketIndex in 0..<buckets.count {
            let offset = bucketIndex * buckets.stride
            let indexID = buckets.bytes.readUInt16(at: offset)
            let area = buckets.bytes.readUInt32(at: offset + 4)
            let entryStart = Int(buckets.bytes.readUInt32(at: offset + 8))
            let entryCount = Int(buckets.bytes.readUInt32(at: offset + 12))
            let treeStart = Int(buckets.bytes.readUInt32(at: offset + 16))
            let leafBase = Int(buckets.bytes.readUInt32(at: offset + 20))
            let key = (indexID, area)
            guard
                previousKey == nil
                    || previousKey!.0 < key.0
                    || (previousKey!.0 == key.0 && previousKey!.1 < key.1),
                let nameCount = namesByIndex[indexID],
                entryStart <= entries.count,
                entryCount <= entries.count - entryStart,
                leafBase > 0,
                leafBase & (leafBase - 1) == 0,
                leafBase
                    >= (entryCount + PackedRadixIndexLayout.namesPerLeaf - 1)
                        / PackedRadixIndexLayout.namesPerLeaf,
                treeStart <= trees.count,
                leafBase <= (trees.count - treeStart) / 2
            else {
                throw DatabaseFormatError.invalidSection(
                    kind,
                    "area bucket \(bucketIndex) has invalid ranges"
                )
            }
            var previousOrdinal: UInt32?
            for entry in entryStart..<entryStart + entryCount {
                let ordinal = entries.bytes.readUInt32(at: entry * entries.stride)
                guard
                    ordinal < nameCount,
                    previousOrdinal == nil || previousOrdinal! < ordinal
                else {
                    throw DatabaseFormatError.invalidSection(
                        kind,
                        "area bucket \(bucketIndex) has invalid name ordinals"
                    )
                }
                previousOrdinal = ordinal
            }
            previousKey = key
        }
    }

    private static func validateAdministrativeAliases(
        records: MappedDatabaseSection,
        strings: MappedDatabaseSection,
        candidates: MappedDatabaseSection,
        languageCount: Int
    ) throws {
        func stringBytes(offset: UInt32) throws -> UnsafeRawBufferPointer {
            let position = Int(offset)
            guard
                position <= strings.bytes.count,
                strings.bytes.count - position >= 4
            else {
                throw DatabaseFormatError.invalidStringOffset(
                    section: .administrativeAliasStrings,
                    offset: offset
                )
            }
            let length = Int(strings.bytes.readUInt32(at: position))
            guard length <= strings.bytes.count - position - 4 else {
                throw DatabaseFormatError.invalidStringOffset(
                    section: .administrativeAliasStrings,
                    offset: offset
                )
            }
            return UnsafeRawBufferPointer(
                rebasing: strings.bytes[
                    position + 4..<position + 4 + length
                ]
            )
        }

        func compare(
            _ lhs: UnsafeRawBufferPointer,
            _ rhs: UnsafeRawBufferPointer
        ) -> Int {
            for index in 0..<min(lhs.count, rhs.count) where lhs[index] != rhs[index] {
                return lhs[index] < rhs[index] ? -1 : 1
            }
            if lhs.count == rhs.count {
                return 0
            }
            return lhs.count < rhs.count ? -1 : 1
        }

        var previousKind: UInt8?
        var previousLanguage: UInt16 = 0
        var previousName: UnsafeRawBufferPointer?
        for recordIndex in 0..<records.count {
            let offset = recordIndex * records.stride
            let rawKind = records.bytes[offset]
            guard
                let kind = AdministrativeAliasKind(rawValue: rawKind),
                records.bytes[offset + 1] == 0,
                records.bytes.readUInt16(at: offset + 14) == 0
            else {
                throw DatabaseFormatError.invalidSection(
                    .administrativeAliasRecords,
                    "record \(recordIndex) has invalid kind or reserved fields"
                )
            }
            let language = records.bytes.readUInt16(at: offset + 2)
            guard
                kind == .localized
                    ? Int(language) < languageCount
                    : language == 0
            else {
                throw DatabaseFormatError.invalidSection(
                    .administrativeAliasRecords,
                    "record \(recordIndex) has an invalid language"
                )
            }
            let name = try stringBytes(
                offset: records.bytes.readUInt32(at: offset + 4)
            )
            let start = Int(records.bytes.readUInt32(at: offset + 8))
            let count = Int(records.bytes.readUInt16(at: offset + 12))
            guard
                count > 0,
                start <= candidates.count,
                count <= candidates.count - start
            else {
                throw DatabaseFormatError.invalidSection(
                    .administrativeAliasRecords,
                    "record \(recordIndex) has an invalid candidate range"
                )
            }
            if let previousKind {
                let isOrdered =
                    previousKind < rawKind
                    || (previousKind == rawKind && previousLanguage < language)
                    || (previousKind == rawKind && previousLanguage == language
                        && compare(previousName!, name) < 0)
                guard isOrdered else {
                    throw DatabaseFormatError.invalidSection(
                        .administrativeAliasRecords,
                        "alias records are not strictly ordered"
                    )
                }
            }
            previousKind = rawKind
            previousLanguage = language
            previousName = name

            var previousCandidate: (UInt32, UInt16)?
            for candidateIndex in start..<start + count {
                let candidateOffset = candidateIndex * candidates.stride
                let admin = candidates.bytes.readUInt32(at: candidateOffset)
                let country = candidates.bytes.readUInt16(at: candidateOffset + 4)
                let key = (admin, country)
                guard
                    country != 0,
                    candidates.bytes.readUInt16(at: candidateOffset + 6) == 0,
                    previousCandidate == nil
                        || previousCandidate!.0 < key.0
                        || (previousCandidate!.0 == key.0
                            && previousCandidate!.1 < key.1)
                else {
                    throw DatabaseFormatError.invalidSection(
                        .administrativeAliasCandidates,
                        "candidate \(candidateIndex) is invalid or unordered"
                    )
                }
                previousCandidate = key
            }
        }
    }

    static func countryValue(_ string: String) -> UInt16? {
        let normalized =
            string
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let bytes = Array(normalized.utf8)
        guard bytes.count == 2, bytes[0] < 128, bytes[1] < 128 else {
            return nil
        }
        return UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
    }

    static func countryString(_ value: UInt16) -> String {
        guard value != 0 else {
            return ""
        }
        return String(
            bytes: [
                UInt8(truncatingIfNeeded: value),
                UInt8(truncatingIfNeeded: value >> 8),
            ],
            encoding: .ascii
        ) ?? ""
    }
}
