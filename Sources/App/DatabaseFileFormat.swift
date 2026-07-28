import Foundation

enum DatabaseFormatError: Error, CustomStringConvertible {
    case invalidMagic
    case unsupportedVersion(UInt32)
    case invalidHeader(String)
    case missingSection(DatabaseSectionKind)
    case invalidSection(DatabaseSectionKind, String)
    case invalidStringOffset(section: DatabaseSectionKind, offset: UInt32)

    var description: String {
        switch self {
        case .invalidMagic:
            return "The file is not a supported geocoding database file."
        case .unsupportedVersion(let version):
            return "Unsupported geocoding database format version \(version)."
        case .invalidHeader(let reason):
            return "Invalid geocoding database header: \(reason)"
        case .missingSection(let section):
            return "Required database section \(section) is missing."
        case .invalidSection(let section, let reason):
            return "Invalid database section \(section): \(reason)"
        case .invalidStringOffset(let section, let offset):
            return "String offset \(offset) is outside database section \(section)."
        }
    }
}

enum DatabaseSectionKind: UInt32, CaseIterable, CustomStringConvertible {
    case idToRow = 1
    case rowToID = 2
    case latitude = 3
    case longitude = 4
    case ranking = 5
    case elevation = 6
    case feature = 7
    case countryISO2 = 8
    case countryID = 9
    case admin1ID = 10
    case admin2ID = 11
    case admin3ID = 12
    case admin4ID = 13
    case timezoneIndex = 14
    case population = 15
    case nameOffset = 16
    case alternateStart = 17
    case alternateCount = 18
    case postcodeStart = 19
    case postcodeCount = 20
    case canonicalStrings = 21
    case alternateRecords = 22
    case alternateStrings = 23
    case postcodeOffsets = 24
    case postcodeStrings = 25
    case featureStrings = 26
    case timezoneStrings = 27
    case languageStrings = 28
    case geoOrdered = 29
    case geoValues = 30
    case searchRoots = 31
    case searchNodes = 32
    case searchEdges = 33
    case searchEdgeLabels = 34
    case searchNameMetadata = 35
    case searchPostings = 36
    case searchGlobalTrees = 37
    case searchCountryBuckets = 38
    case searchCountryEntries = 39
    case searchCountryTrees = 40
    case searchAdminBuckets = 41
    case searchAdminEntries = 42
    case searchAdminTrees = 43

    var description: String {
        return "section-\(rawValue)"
    }
}

struct DatabaseSectionDescriptor: Equatable {
    static let encodedSize = 48

    let kind: DatabaseSectionKind
    let flags: UInt32
    let offset: UInt64
    let length: UInt64
    let count: UInt64
    let stride: UInt32
    let hash: UInt64

    func encode(into data: inout Data, at offset: Int) {
        data.writeLittleEndian(kind.rawValue, at: offset)
        data.writeLittleEndian(flags, at: offset + 4)
        data.writeLittleEndian(self.offset, at: offset + 8)
        data.writeLittleEndian(length, at: offset + 16)
        data.writeLittleEndian(count, at: offset + 24)
        data.writeLittleEndian(stride, at: offset + 32)
        data.writeLittleEndian(UInt32(0), at: offset + 36)
        data.writeLittleEndian(hash, at: offset + 40)
    }
}

struct DatabaseFileHeader {
    static let magic = Array("GEOCDV2\u{0}".utf8)
    static let formatVersion: UInt32 = 2
    static let encodedSize = 4096
    static let directoryOffset = 64
    static let maximumSectionCount =
        (encodedSize - directoryOffset) / DatabaseSectionDescriptor.encodedSize

    let fileSize: UInt64
    let recordCount: UInt32
    let maximumGeonameID: UInt32
    let geonamesFingerprint: UInt64
    let alternateNamesFingerprint: UInt64
    let sections: [DatabaseSectionKind: DatabaseSectionDescriptor]

    init(
        fileSize: UInt64,
        recordCount: UInt32,
        maximumGeonameID: UInt32,
        geonamesFingerprint: UInt64,
        alternateNamesFingerprint: UInt64,
        sectionDescriptors: [DatabaseSectionDescriptor]
    ) throws {
        guard sectionDescriptors.count <= Self.maximumSectionCount else {
            throw DatabaseFormatError.invalidHeader("too many sections")
        }
        var sections = [DatabaseSectionKind: DatabaseSectionDescriptor]()
        sections.reserveCapacity(sectionDescriptors.count)
        for descriptor in sectionDescriptors {
            guard sections.updateValue(descriptor, forKey: descriptor.kind) == nil else {
                throw DatabaseFormatError.invalidHeader("duplicate section \(descriptor.kind)")
            }
        }
        self.fileSize = fileSize
        self.recordCount = recordCount
        self.maximumGeonameID = maximumGeonameID
        self.geonamesFingerprint = geonamesFingerprint
        self.alternateNamesFingerprint = alternateNamesFingerprint
        self.sections = sections
    }

    init(mappedFile: MappedFile) throws {
        guard mappedFile.count >= Self.encodedSize else {
            throw DatabaseFormatError.invalidHeader("file is shorter than the header")
        }
        let bytes = try mappedFile.bytes(offset: 0, length: UInt64(Self.encodedSize))
        guard Array(bytes.prefix(Self.magic.count)) == Self.magic else {
            throw DatabaseFormatError.invalidMagic
        }
        let version = bytes.readUInt32(at: 8)
        guard version == Self.formatVersion else {
            throw DatabaseFormatError.unsupportedVersion(version)
        }
        guard bytes.readUInt32(at: 12) == UInt32(Self.encodedSize) else {
            throw DatabaseFormatError.invalidHeader("unexpected header size")
        }

        let fileSize = bytes.readUInt64(at: 16)
        guard fileSize == UInt64(mappedFile.count) else {
            throw DatabaseFormatError.invalidHeader(
                "declared file size \(fileSize) does not match \(mappedFile.count)"
            )
        }
        let recordCount = bytes.readUInt32(at: 24)
        let maximumGeonameID = bytes.readUInt32(at: 28)
        let geonamesFingerprint = bytes.readUInt64(at: 32)
        let alternateNamesFingerprint = bytes.readUInt64(at: 40)
        let sectionCount = Int(bytes.readUInt32(at: 48))
        guard sectionCount <= Self.maximumSectionCount else {
            throw DatabaseFormatError.invalidHeader("section directory is too large")
        }

        var descriptors = [DatabaseSectionDescriptor]()
        descriptors.reserveCapacity(sectionCount)
        for index in 0..<sectionCount {
            let base = Self.directoryOffset + index * DatabaseSectionDescriptor.encodedSize
            guard let kind = DatabaseSectionKind(rawValue: bytes.readUInt32(at: base)) else {
                throw DatabaseFormatError.invalidHeader("unknown section kind")
            }
            let descriptor = DatabaseSectionDescriptor(
                kind: kind,
                flags: bytes.readUInt32(at: base + 4),
                offset: bytes.readUInt64(at: base + 8),
                length: bytes.readUInt64(at: base + 16),
                count: bytes.readUInt64(at: base + 24),
                stride: bytes.readUInt32(at: base + 32),
                hash: bytes.readUInt64(at: base + 40)
            )
            guard
                descriptor.offset >= UInt64(Self.encodedSize),
                descriptor.offset <= fileSize,
                descriptor.length <= fileSize - descriptor.offset
            else {
                throw DatabaseFormatError.invalidSection(kind, "range is outside the file")
            }
            if descriptor.stride > 0 {
                guard descriptor.count <= UInt64.max / UInt64(descriptor.stride) else {
                    throw DatabaseFormatError.invalidSection(kind, "count overflows section size")
                }
                guard descriptor.count * UInt64(descriptor.stride) == descriptor.length else {
                    throw DatabaseFormatError.invalidSection(kind, "count and stride do not match length")
                }
            }
            descriptors.append(descriptor)
        }

        try self.init(
            fileSize: fileSize,
            recordCount: recordCount,
            maximumGeonameID: maximumGeonameID,
            geonamesFingerprint: geonamesFingerprint,
            alternateNamesFingerprint: alternateNamesFingerprint,
            sectionDescriptors: descriptors
        )
    }

    func encoded() -> Data {
        var data = Data(repeating: 0, count: Self.encodedSize)
        data.replaceSubrange(0..<Self.magic.count, with: Self.magic)
        data.writeLittleEndian(Self.formatVersion, at: 8)
        data.writeLittleEndian(UInt32(Self.encodedSize), at: 12)
        data.writeLittleEndian(fileSize, at: 16)
        data.writeLittleEndian(recordCount, at: 24)
        data.writeLittleEndian(maximumGeonameID, at: 28)
        data.writeLittleEndian(geonamesFingerprint, at: 32)
        data.writeLittleEndian(alternateNamesFingerprint, at: 40)
        let descriptors = sections.values.sorted { $0.kind.rawValue < $1.kind.rawValue }
        data.writeLittleEndian(UInt32(descriptors.count), at: 48)
        for (index, descriptor) in descriptors.enumerated() {
            descriptor.encode(
                into: &data,
                at: Self.directoryOffset + index * DatabaseSectionDescriptor.encodedSize
            )
        }
        return data
    }
}

struct MappedDatabaseSection: @unchecked Sendable {
    let kind: DatabaseSectionKind
    let bytes: UnsafeRawBufferPointer
    let count: Int
    let stride: Int

    func uint8(at index: Int) -> UInt8 {
        precondition(stride == 1 && index >= 0 && index < count)
        return bytes[index]
    }

    func uint16(at index: Int) -> UInt16 {
        precondition(stride == 2 && index >= 0 && index < count)
        return bytes.readUInt16(at: index * stride)
    }

    func int16(at index: Int) -> Int16 {
        return Int16(bitPattern: uint16(at: index))
    }

    func uint32(at index: Int) -> UInt32 {
        precondition(stride == 4 && index >= 0 && index < count)
        return bytes.readUInt32(at: index * stride)
    }

    func int32(at index: Int) -> Int32 {
        return Int32(bitPattern: uint32(at: index))
    }

    func float32(at index: Int) -> Float {
        return Float(bitPattern: uint32(at: index))
    }

    func uint64(at index: Int) -> UInt64 {
        precondition(stride == 8 && index >= 0 && index < count)
        return bytes.readUInt64(at: index * stride)
    }
}

extension UnsafeRawBufferPointer {
    func readUInt16(at offset: Int) -> UInt16 {
        precondition(offset >= 0 && offset + 2 <= count)
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func readUInt32(at offset: Int) -> UInt32 {
        precondition(offset >= 0 && offset + 4 <= count)
        return UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }

    func readUInt64(at offset: Int) -> UInt64 {
        precondition(offset >= 0 && offset + 8 <= count)
        return UInt64(readUInt32(at: offset))
            | (UInt64(readUInt32(at: offset + 4)) << 32)
    }
}

extension Data {
    mutating func writeLittleEndian(_ value: UInt16, at offset: Int) {
        self[offset] = UInt8(truncatingIfNeeded: value)
        self[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    mutating func writeLittleEndian(_ value: UInt32, at offset: Int) {
        self[offset] = UInt8(truncatingIfNeeded: value)
        self[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        self[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        self[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    mutating func writeLittleEndian(_ value: UInt64, at offset: Int) {
        writeLittleEndian(UInt32(truncatingIfNeeded: value), at: offset)
        writeLittleEndian(UInt32(truncatingIfNeeded: value >> 32), at: offset + 4)
    }
}
