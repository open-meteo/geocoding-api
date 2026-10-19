import Foundation
import Logging
import Vapor

final class GeocodingDatabase: Sendable {
    static let databaseFile = GeocodingDatabaseBuilder.databaseFile

    let mappedFile: MappedFile
    let header: DatabaseFileHeader
    let languages: [String]
    let timezones: [String]
    let features: [String]
    let languageIDs: [String: UInt16]

    private let idToRow: MappedDatabaseSection
    private let locations: MappedDatabaseSection

    private let canonicalStrings: MappedBytes
    private let alternateRecords: MappedBytes
    private let alternateStrings: MappedBytes
    private let postcodeOffsets: MappedDatabaseSection
    private let postcodeStrings: MappedBytes
    private let mappedSections: [DatabaseSectionKind: MappedBytes]

    let searchIndex: PackedRadixSearchIndex

    enum Verification { case structure, full }

    init(url: URL = GeocodingDatabase.databaseFile, verification: Verification = .full) throws {
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
                kind: kind,
                bytes: try mappedFile.bytes(
                    offset: descriptor.offset,
                    length: descriptor.length
                ),
                count: compactCount,
                stride: compactStride
            )
        }

        func raw(_ kind: DatabaseSectionKind) throws -> MappedBytes {
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
        locations = try fixed(.locations, stride: UInt32(LocationRecordLayout.stride), count: records)

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
        guard languages.count < Int(UInt16.max), Set(languages).count == languages.count else {
            throw DatabaseFormatError.invalidSection(.languageStrings, "duplicate or excessive language IDs")
        }
        languageIDs = Dictionary(
            uniqueKeysWithValues: languages.enumerated().map {
                ($0.element, UInt16($0.offset))
            }
        )

        let searchRoots = try fixed(
            .searchRoots,
            stride: UInt32(RadixRootLayout.stride)
        )
        let searchNodes = try fixed(
            .searchNodes,
            stride: UInt32(RadixNodeLayout.stride)
        )
        let searchEdges = try fixed(
            .searchEdges,
            stride: UInt32(RadixEdgeLayout.stride)
        )
        let searchLabels = try fixed(.searchEdgeLabels, stride: 1)
        let searchMetadata = try fixed(
            .searchNameMetadata,
            stride: UInt32(NameMetadataLayout.stride)
        )
        let searchPostings = try fixed(
            .searchPostings,
            stride: UInt32(SearchPostingLayout.stride)
        )
        let searchGlobalTrees = try fixed(
            .searchGlobalTrees,
            stride: UInt32(PackedRadixIndexLayout.treeNodeStride)
        )
        let searchCountryBuckets = try fixed(
            .searchCountryBuckets,
            stride: UInt32(AreaBucketLayout.stride)
        )
        let searchCountryEntries = try fixed(
            .searchCountryEntries,
            stride: UInt32(AreaEntryLayout.stride)
        )
        let searchCountryTrees = try fixed(
            .searchCountryTrees,
            stride: UInt32(PackedRadixIndexLayout.treeNodeStride)
        )
        let searchAdminBuckets = try fixed(
            .searchAdminBuckets,
            stride: UInt32(AreaBucketLayout.stride)
        )
        let searchAdminEntries = try fixed(
            .searchAdminEntries,
            stride: UInt32(AreaEntryLayout.stride)
        )
        let searchAdminTrees = try fixed(
            .searchAdminTrees,
            stride: UInt32(PackedRadixIndexLayout.treeNodeStride)
        )
        let administrativeAliasRecords = try fixed(
            .administrativeAliasRecords,
            stride: UInt32(AdministrativeAliasRecordLayout.stride)
        )
        let administrativeAliasStrings = try fixed(
            .administrativeAliasStrings,
            stride: 1
        )
        let administrativeAliasCandidates = try fixed(
            .administrativeAliasCandidates,
            stride: UInt32(AdministrativeAliasCandidateLayout.stride)
        )
        if verification == .full {
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
        }
        let mappedSections: [DatabaseSectionKind: MappedBytes] = [
            .locations: locations.bytes,
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
        self.mappedSections = mappedSections
        searchIndex = try PackedRadixSearchIndex(
            header: header,
            sections: mappedSections
        )

        func validateStringOffset(
            pool: MappedBytes,
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
            guard length <= pool.count - position - 4,
                pool.span.extracting(position + 4..<position + 4 + length).decodedUTF8() != nil
            else {
                throw DatabaseFormatError.invalidStringOffset(
                    section: section,
                    offset: offset
                )
            }
        }

        if verification == .full {
            mappedFile.releaseResidentPages()
            for descriptor in header.sections.values {
                var hasher = XXHash64()
                let bytes = try mappedFile.bytes(offset: descriptor.offset, length: descriptor.length)
                hasher.update(bytes.span)
                guard hasher.digest() == descriptor.hash else {
                    throw DatabaseFormatError.invalidSection(descriptor.kind, "checksum mismatch")
                }
                mappedFile.releaseResidentPages()
            }
            for row in 0..<Int(header.recordCount) {
                if row.isMultiple(of: 65_536) { mappedFile.releaseResidentPages() }
                guard location(row).reservedIsZero else {
                    throw DatabaseFormatError.invalidSection(.locations, "nonzero reserved record bytes")
                }
                let id = location(row).id
                guard
                    id <= header.maximumGeonameID,
                    idToRow.uint32(at: Int(id)) == UInt32(row)
                else {
                    throw DatabaseFormatError.invalidSection(
                        .locations,
                        "row \(row) is inconsistent with the dense ID map"
                    )
                }
                guard
                    location(row).latitude.isFinite,
                    location(row).longitude.isFinite
                else {
                    throw DatabaseFormatError.invalidSection(
                        .locations,
                        "row \(row) contains a non-finite coordinate or rank"
                    )
                }
                guard Int(location(row).feature) < features.count else {
                    throw DatabaseFormatError.invalidSection(
                        .locations,
                        "row \(row) has an invalid feature index"
                    )
                }
                guard Int(location(row).timezone) < timezones.count else {
                    throw DatabaseFormatError.invalidSection(
                        .locations,
                        "row \(row) has an invalid timezone index"
                    )
                }
                try validateStringOffset(
                    pool: canonicalStrings,
                    offset: location(row).nameOffset,
                    section: .canonicalStrings
                )

                let alternateStart = Int(location(row).alternateStart)
                let alternateCount = Int(location(row).alternateCount)
                guard
                    alternateStart <= alternateRecords.count / AlternateNameRecordLayout.stride,
                    alternateCount <= alternateRecords.count / AlternateNameRecordLayout.stride - alternateStart
                else {
                    throw DatabaseFormatError.invalidSection(
                        .alternateRecords,
                        "row \(row) has an invalid alternate-name range"
                    )
                }
                var previousLanguage: UInt16?
                for index in 0..<alternateCount {
                    let offset = (alternateStart + index) * AlternateNameRecordLayout.stride
                    let language = alternateRecords.readUInt16(at: offset + AlternateNameRecordLayout.languageID)
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
                        offset: alternateRecords.readUInt32(at: offset + AlternateNameRecordLayout.nameOffset),
                        section: .alternateStrings
                    )
                    previousLanguage = language
                }

                let postcodeStart = Int(location(row).postcodeStart)
                let postcodeCount = Int(location(row).postcodeCount)
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
            try Self.validateRankSummaries(header: header, sections: mappedSections, mappedFile: mappedFile)
            mappedFile.releaseResidentPages()
            for id in 0..<idToRow.count {
                let row = idToRow.uint32(at: id)
                guard row == UInt32.max || (row < header.recordCount && location(Int(row)).id == UInt32(id)) else {
                    throw DatabaseFormatError.invalidSection(.idToRow, "inconsistent ID map entry")
                }
            }
        }
        if verification == .full { mappedFile.releaseResidentPages() }
        mappedFile.optimizeForRandomAccess()
    }

    static func open(logger: Logger, url: URL = databaseFile) throws -> GeocodingDatabase {
        do {
            return try GeocodingDatabase(url: url, verification: .structure)
        } catch {
            logger.error(
                "Could not open prebuilt database at \(url.path): \(error). Run build-database and verify-database before starting the service."
            )
            throw error
        }
    }

    var recordCount: Int {
        return Int(header.recordCount)
    }

    func sectionBytes(_ kind: DatabaseSectionKind) -> MappedBytes {
        return mappedSections[kind]!
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

    private func location(_ row: Int) -> LocationRecordView {
        LocationRecordView(section: locations, row: row)
    }

    func id(row: Int) -> Int32 {
        return Int32(bitPattern: location(row).id)
    }

    func latitude(row: Int) -> Float {
        return location(row).latitude
    }

    func longitude(row: Int) -> Float {
        return location(row).longitude
    }

    func featureIndex(row: Int) -> UInt8 {
        return location(row).feature
    }

    func feature(row: Int) -> String {
        return features[Int(featureIndex(row: row))]
    }

    func countryISO2Value(row: Int) -> UInt16 {
        return location(row).country
    }

    func countryISO2(row: Int) -> String {
        return Self.countryString(countryISO2Value(row: row))
    }

    func countryID(row: Int) -> Int32 {
        return location(row).countryID
    }

    func admin1ID(row: Int) -> Int32 {
        return location(row).admin1ID
    }

    func admin2ID(row: Int) -> Int32 {
        return location(row).admin2ID
    }

    func admin3ID(row: Int) -> Int32 {
        return location(row).admin3ID
    }

    func admin4ID(row: Int) -> Int32 {
        return location(row).admin4ID
    }

    func population(row: Int) -> UInt32 {
        return location(row).population
    }

    func name(row: Int, languageID: UInt16) throws -> String {
        let start = Int(location(row).alternateStart)
        let count = Int(location(row).alternateCount)
        guard start <= alternateRecords.count / AlternateNameRecordLayout.stride,
            count <= alternateRecords.count / AlternateNameRecordLayout.stride - start
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
            let record = (start + middle) * AlternateNameRecordLayout.stride
            if alternateRecords.readUInt16(at: record + AlternateNameRecordLayout.languageID) < languageID {
                low = middle + 1
            } else {
                high = middle
            }
        }
        if low < count {
            let record = (start + low) * AlternateNameRecordLayout.stride
            if alternateRecords.readUInt16(at: record + AlternateNameRecordLayout.languageID) == languageID {
                return try string(
                    pool: alternateStrings,
                    offset: alternateRecords.readUInt32(at: record + AlternateNameRecordLayout.nameOffset),
                    section: .alternateStrings
                )
            }
        }
        return try string(
            pool: canonicalStrings,
            offset: location(row).nameOffset,
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
        var names = [Int: String]()
        return try response(row: row, languageID: languageID, names: &names)
    }

    func responses(hits: [SearchHit], languageID: UInt16) throws -> [GeocodingApi.Geoname] {
        var names = [Int: String]()
        return try hits.map { try response(row: Int($0.row), languageID: languageID, names: &names) }
    }

    private func response(row: Int, languageID: UInt16, names: inout [Int: String]) throws -> GeocodingApi.Geoname {
        guard row >= 0, row < recordCount else { throw GeocodingApiError.databaseInvariant }
        let record = location(row)
        guard Int(record.feature) < features.count, Int(record.timezone) < timezones.count else {
            throw DatabaseFormatError.invalidSection(.locations, "invalid feature or timezone reference")
        }
        var output = GeocodingApi.Geoname()
        output.id = Int32(bitPattern: record.id)
        output.name = try name(row: row, languageID: languageID)
        output.latitude = record.latitude
        output.longitude = record.longitude
        output.elevation = Float(record.elevation)
        output.countryCode = Self.countryString(record.country)
        output.countryID = record.countryID
        output.country = try referencedName(
            id: output.countryID,
            languageID: languageID,
            names: &names
        )
        output.featureCode = features[Int(record.feature)]
        output.admin1ID = record.admin1ID
        output.admin2ID = record.admin2ID
        output.admin3ID = record.admin3ID
        output.admin4ID = record.admin4ID
        output.admin1 = try referencedName(id: output.admin1ID, languageID: languageID, names: &names)
        output.admin2 = try referencedName(id: output.admin2ID, languageID: languageID, names: &names)
        output.admin3 = try referencedName(id: output.admin3ID, languageID: languageID, names: &names)
        output.admin4 = try referencedName(id: output.admin4ID, languageID: languageID, names: &names)
        output.population = record.population
        output.timezone = timezones[Int(record.timezone)]

        let postcodeStart = Int(record.postcodeStart)
        let postcodeCount = Int(record.postcodeCount)
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
        languageID: UInt16,
        names: inout [Int: String]
    ) throws -> String {
        guard let row = row(for: id) else {
            return ""
        }
        if let cached = names[row] { return cached }
        let value = try name(row: row, languageID: languageID)
        names[row] = value
        return value
    }

    private func string(
        pool: MappedBytes,
        offset: UInt32,
        section: DatabaseSectionKind
    ) throws -> String {
        guard let value = try stringBytes(in: pool.span, offset: offset, section: section).decodedUTF8() else {
            throw DatabaseFormatError.invalidSection(section, "string is not valid UTF-8")
        }
        return value
    }

    private static func decodeStringTable(
        bytes: MappedBytes,
        count: UInt64,
        kind: DatabaseSectionKind
    ) throws -> [String] {
        guard let expectedCount = Int(exactly: count), expectedCount <= bytes.count / 4 else {
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
                let value = bytes.span.extracting(offset..<offset + length).decodedUTF8()
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
            let indexID = roots.bytes.readUInt16(at: offset + RadixRootLayout.indexID)
            let rootNode = Int(roots.bytes.readUInt32(at: offset + RadixRootLayout.rootNode))
            let nameBase = Int(roots.bytes.readUInt32(at: offset + RadixRootLayout.nameBase))
            let nameCount = Int(roots.bytes.readUInt32(at: offset + RadixRootLayout.nameCount))
            let treeStart = Int(roots.bytes.readUInt32(at: offset + RadixRootLayout.treeStart))
            let leafBase = Int(roots.bytes.readUInt32(at: offset + RadixRootLayout.treeLeafBase))
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
            let firstEdge = Int(nodes.bytes.readUInt32(at: offset + RadixNodeLayout.firstEdge))
            let edgeCount = Int(nodes.bytes.readUInt16(at: offset + RadixNodeLayout.edgeCount))
            guard
                firstEdge <= edges.count,
                edgeCount <= edges.count - firstEdge,
                nodes.bytes.readUInt32(at: offset + RadixNodeLayout.subtreeCount) > 0
            else {
                throw DatabaseFormatError.invalidSection(
                    .searchNodes,
                    "node \(nodeIndex) has invalid edge or subtree ranges"
                )
            }
        }

        for edgeIndex in 0..<edges.count {
            let offset = edgeIndex * edges.stride
            let encodedChild = edges.bytes.readUInt32(at: offset + RadixEdgeLayout.child)
            let isLeaf = encodedChild & RadixEdgeLayout.leafFlag != 0
            let child = Int(encodedChild & RadixEdgeLayout.childMask)
            let labelOffset = Int(edges.bytes.readUInt32(at: offset + RadixEdgeLayout.labelOffset))
            let labelLength = Int(edges.bytes.readUInt16(at: offset + RadixEdgeLayout.labelLength))
            guard
                isLeaf || child < nodes.count,
                labelLength > 0,
                labelOffset <= labels.count,
                labelLength <= labels.count - labelOffset,
                labels.bytes[labelOffset] == edges.bytes[offset + RadixEdgeLayout.firstByte]
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
                let first = nodes.bytes.readUInt32(at: nodeOffset + RadixNodeLayout.subtreeFirst)
                let count = nodes.bytes.readUInt32(at: nodeOffset + RadixNodeLayout.subtreeCount)
                guard first < root.nameCount, count <= root.nameCount - first else {
                    throw DatabaseFormatError.invalidSection(
                        .searchNodes,
                        "radix subtree ordinal range is invalid"
                    )
                }
                let firstEdge = Int(nodes.bytes.readUInt32(at: nodeOffset + RadixNodeLayout.firstEdge))
                let edgeCount = Int(nodes.bytes.readUInt16(at: nodeOffset + RadixNodeLayout.edgeCount))
                var previousFirstByte: UInt8?
                for edgeIndex in firstEdge..<firstEdge + edgeCount {
                    let edgeOffset = edgeIndex * edges.stride
                    let firstByte = edges.bytes[edgeOffset + RadixEdgeLayout.firstByte]
                    guard previousFirstByte == nil || previousFirstByte! < firstByte else {
                        throw DatabaseFormatError.invalidSection(
                            .searchEdges,
                            "radix node edges are not strictly ordered"
                        )
                    }
                    previousFirstByte = firstByte
                    let encodedChild = edges.bytes.readUInt32(at: edgeOffset + RadixEdgeLayout.child)
                    let child = encodedChild & RadixEdgeLayout.childMask
                    if encodedChild & RadixEdgeLayout.leafFlag == 0 {
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
            let start = Int(metadata.bytes.readUInt32(at: offset + NameMetadataLayout.postingStart))
            let count = Int(metadata.bytes.readUInt32(at: offset + NameMetadataLayout.postingCount))
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
                let row = postings.bytes.readUInt32(at: postingOffset + SearchPostingLayout.row)
                let rank = Float(
                    bitPattern: postings.bytes.readUInt32(
                        at: postingOffset + SearchPostingLayout.rank
                    )
                )
                guard
                    row < UInt32(recordCount),
                    rank.isFinite, rank >= 0,
                    rank <= Float(UInt16.max - 1) / PackedRadixIndexLayout.rankScale,
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
            let indexID = buckets.bytes.readUInt16(at: offset + AreaBucketLayout.indexID)
            let area = buckets.bytes.readUInt32(at: offset + AreaBucketLayout.area)
            let entryStart = Int(buckets.bytes.readUInt32(at: offset + AreaBucketLayout.entryStart))
            let entryCount = Int(buckets.bytes.readUInt32(at: offset + AreaBucketLayout.entryCount))
            let treeStart = Int(buckets.bytes.readUInt32(at: offset + AreaBucketLayout.treeStart))
            let leafBase = Int(buckets.bytes.readUInt32(at: offset + AreaBucketLayout.treeLeafBase))
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
                let ordinal = entries.bytes.readUInt32(at: entry * entries.stride + AreaEntryLayout.nameOrdinal)
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
        func compare(
            _ lhs: borrowing Span<UInt8>,
            _ rhs: borrowing Span<UInt8>
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
        var previousNameOffset: UInt32?
        for recordIndex in 0..<records.count {
            let offset = recordIndex * records.stride
            let rawKind = records.bytes[offset + AdministrativeAliasRecordLayout.kind]
            guard
                let kind = AdministrativeAliasKind(rawValue: rawKind),
                records.bytes[offset + AdministrativeAliasRecordLayout.reserved] == 0,
                records.bytes.readUInt16(at: offset + AdministrativeAliasRecordLayout.trailingReserved) == 0
            else {
                throw DatabaseFormatError.invalidSection(
                    .administrativeAliasRecords,
                    "record \(recordIndex) has invalid kind or reserved fields"
                )
            }
            let language = records.bytes.readUInt16(at: offset + AdministrativeAliasRecordLayout.languageID)
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
            let nameOffset = records.bytes.readUInt32(at: offset + AdministrativeAliasRecordLayout.nameOffset)
            let name = try stringBytes(in: strings.bytes.span, offset: nameOffset, section: .administrativeAliasStrings)
            let start = Int(records.bytes.readUInt32(at: offset + AdministrativeAliasRecordLayout.candidateStart))
            let count = Int(records.bytes.readUInt16(at: offset + AdministrativeAliasRecordLayout.candidateCount))
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
                    try previousKind < rawKind
                    || (previousKind == rawKind && previousLanguage < language)
                    || (previousKind == rawKind && previousLanguage == language
                        && compare(
                            try stringBytes(in: strings.bytes.span, offset: previousNameOffset!, section: .administrativeAliasStrings),
                            name
                        ) < 0)
                guard isOrdered else {
                    throw DatabaseFormatError.invalidSection(
                        .administrativeAliasRecords,
                        "alias records are not strictly ordered"
                    )
                }
            }
            previousKind = rawKind
            previousLanguage = language
            previousNameOffset = nameOffset

            var previousCandidate: (UInt32, UInt16)?
            for candidateIndex in start..<start + count {
                let candidateOffset = candidateIndex * candidates.stride
                let admin = candidates.bytes.readUInt32(
                    at: candidateOffset + AdministrativeAliasCandidateLayout.admin1ID
                )
                let country = candidates.bytes.readUInt16(
                    at: candidateOffset + AdministrativeAliasCandidateLayout.country
                )
                let key = (admin, country)
                guard
                    country != 0,
                    candidates.bytes.readUInt16(at: candidateOffset + AdministrativeAliasCandidateLayout.reserved) == 0,
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
