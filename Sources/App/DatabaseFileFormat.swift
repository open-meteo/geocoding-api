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

enum DatabaseSectionKind: UInt32, CaseIterable, CustomStringConvertible, Sendable {
    case idToRow = 1
    case locations = 2
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
    case administrativeAliasRecords = 44
    case administrativeAliasStrings = 45
    case administrativeAliasCandidates = 46

    var description: String {
        return "section-\(rawValue)"
    }
}

private enum SectionDescriptorLayout {
    static let kind = 0
    static let flags = 4
    static let offset = 8
    static let length = 16
    static let count = 24
    static let elementStride = 32
    static let reserved = 36
    static let hash = 40
}

struct DatabaseSectionDescriptor: Equatable, Sendable {
    static let encodedSize = 48

    let kind: DatabaseSectionKind
    let flags: UInt32
    let offset: UInt64
    let length: UInt64
    let count: UInt64
    let stride: UInt32
    let hash: UInt64

    func encode(into data: inout Data, at offset: Int) {
        data.writeLittleEndian(kind.rawValue, at: offset + SectionDescriptorLayout.kind)
        data.writeLittleEndian(flags, at: offset + SectionDescriptorLayout.flags)
        data.writeLittleEndian(self.offset, at: offset + SectionDescriptorLayout.offset)
        data.writeLittleEndian(length, at: offset + SectionDescriptorLayout.length)
        data.writeLittleEndian(count, at: offset + SectionDescriptorLayout.count)
        data.writeLittleEndian(stride, at: offset + SectionDescriptorLayout.elementStride)
        data.writeLittleEndian(UInt32(0), at: offset + SectionDescriptorLayout.reserved)
        data.writeLittleEndian(hash, at: offset + SectionDescriptorLayout.hash)
    }
}

private enum FileHeaderLayout {
    static let version = 8
    static let headerSize = 12
    static let fileSize = 16
    static let recordCount = 24
    static let maximumGeonameID = 28
    static let geonamesFingerprint = 32
    static let alternateNamesFingerprint = 40
    static let sectionCount = 48
    static let normalizationVersion = 52
    static let scoringVersion = 56
    static let reserved = 60
}

struct DatabaseFileHeader: Sendable {
    static let magic = Array("GEOCDV1\u{0}".utf8)
    static let formatVersion: UInt32 = 1
    static let encodedSize = 4096
    static let sectionAlignment: UInt64 = 4096
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
        guard Self.magic.indices.allSatisfy({ bytes[$0] == Self.magic[$0] }) else {
            throw DatabaseFormatError.invalidMagic
        }
        let version = bytes.readUInt32(at: FileHeaderLayout.version)
        guard version == Self.formatVersion else {
            throw DatabaseFormatError.unsupportedVersion(version)
        }
        guard bytes.readUInt32(at: FileHeaderLayout.headerSize) == UInt32(Self.encodedSize) else {
            throw DatabaseFormatError.invalidHeader("unexpected header size")
        }

        let fileSize = bytes.readUInt64(at: FileHeaderLayout.fileSize)
        guard fileSize == UInt64(mappedFile.count) else {
            throw DatabaseFormatError.invalidHeader(
                "declared file size \(fileSize) does not match \(mappedFile.count)"
            )
        }
        let recordCount = bytes.readUInt32(at: FileHeaderLayout.recordCount)
        let maximumGeonameID = bytes.readUInt32(at: FileHeaderLayout.maximumGeonameID)
        let geonamesFingerprint = bytes.readUInt64(at: FileHeaderLayout.geonamesFingerprint)
        let alternateNamesFingerprint = bytes.readUInt64(at: FileHeaderLayout.alternateNamesFingerprint)
        let sectionCount = Int(bytes.readUInt32(at: FileHeaderLayout.sectionCount))
        guard sectionCount <= Self.maximumSectionCount else {
            throw DatabaseFormatError.invalidHeader("section directory is too large")
        }
        guard bytes.readUInt32(at: FileHeaderLayout.normalizationVersion) == SearchScorer.normalizationVersion,
            bytes.readUInt32(at: FileHeaderLayout.scoringVersion) == SearchScorer.version,
            bytes.readUInt32(at: FileHeaderLayout.reserved) == 0
        else {
            throw DatabaseFormatError.invalidHeader("incompatible normalization/scoring version or reserved bytes")
        }

        var descriptors = [DatabaseSectionDescriptor]()
        descriptors.reserveCapacity(sectionCount)
        for index in 0..<sectionCount {
            let base = Self.directoryOffset + index * DatabaseSectionDescriptor.encodedSize
            guard let kind = DatabaseSectionKind(rawValue: bytes.readUInt32(at: base + SectionDescriptorLayout.kind))
            else {
                throw DatabaseFormatError.invalidHeader("unknown section kind")
            }
            let descriptor = DatabaseSectionDescriptor(
                kind: kind,
                flags: bytes.readUInt32(at: base + SectionDescriptorLayout.flags),
                offset: bytes.readUInt64(at: base + SectionDescriptorLayout.offset),
                length: bytes.readUInt64(at: base + SectionDescriptorLayout.length),
                count: bytes.readUInt64(at: base + SectionDescriptorLayout.count),
                stride: bytes.readUInt32(at: base + SectionDescriptorLayout.elementStride),
                hash: bytes.readUInt64(at: base + SectionDescriptorLayout.hash)
            )
            guard
                descriptor.flags == 0,
                bytes.readUInt32(at: base + SectionDescriptorLayout.reserved) == 0,
                descriptor.offset >= UInt64(Self.encodedSize),
                descriptor.offset & (Self.sectionAlignment - 1) == 0,
                descriptor.offset <= fileSize,
                descriptor.length <= fileSize - descriptor.offset
            else {
                throw DatabaseFormatError.invalidSection(
                    kind,
                    "flags, alignment, reserved bytes, or range are invalid"
                )
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
        var previousEnd = UInt64(Self.encodedSize)
        for descriptor in descriptors.sorted(by: { $0.offset < $1.offset }) {
            guard descriptor.offset >= previousEnd else {
                throw DatabaseFormatError.invalidSection(
                    descriptor.kind,
                    "section overlaps an earlier section"
                )
            }
            previousEnd = descriptor.offset + descriptor.length
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
        data.writeLittleEndian(Self.formatVersion, at: FileHeaderLayout.version)
        data.writeLittleEndian(UInt32(Self.encodedSize), at: FileHeaderLayout.headerSize)
        data.writeLittleEndian(fileSize, at: FileHeaderLayout.fileSize)
        data.writeLittleEndian(recordCount, at: FileHeaderLayout.recordCount)
        data.writeLittleEndian(maximumGeonameID, at: FileHeaderLayout.maximumGeonameID)
        data.writeLittleEndian(geonamesFingerprint, at: FileHeaderLayout.geonamesFingerprint)
        data.writeLittleEndian(alternateNamesFingerprint, at: FileHeaderLayout.alternateNamesFingerprint)
        let descriptors = sections.values.sorted { $0.kind.rawValue < $1.kind.rawValue }
        data.writeLittleEndian(UInt32(descriptors.count), at: FileHeaderLayout.sectionCount)
        data.writeLittleEndian(SearchScorer.normalizationVersion, at: FileHeaderLayout.normalizationVersion)
        data.writeLittleEndian(SearchScorer.version, at: FileHeaderLayout.scoringVersion)
        for (index, descriptor) in descriptors.enumerated() {
            descriptor.encode(
                into: &data,
                at: Self.directoryOffset + index * DatabaseSectionDescriptor.encodedSize
            )
        }
        return data
    }
}

struct MappedDatabaseSection: Sendable {
    let kind: DatabaseSectionKind
    let bytes: MappedBytes
    let count: Int
    let stride: Int

    init(
        kind: DatabaseSectionKind,
        bytes: MappedBytes,
        count: Int,
        stride: Int
    ) {
        self.kind = kind
        self.bytes = bytes
        self.count = count
        self.stride = stride
    }

    func withSpan<Result>(
        _ body: (borrowing Span<UInt8>) throws -> Result
    ) rethrows -> Result {
        try bytes.withSpan(body)
    }

    func uint8(at index: Int) -> UInt8 {
        precondition(stride == 1 && index >= 0 && index < count)
        return withSpan { $0[index] }
    }

    func uint16(at index: Int) -> UInt16 {
        precondition(stride == 2 && index >= 0 && index < count)
        return withSpan { $0.readUInt16(at: index * stride) }
    }

    func int16(at index: Int) -> Int16 {
        return Int16(bitPattern: uint16(at: index))
    }

    func uint32(at index: Int) -> UInt32 {
        precondition(stride == 4 && index >= 0 && index < count)
        return withSpan { $0.readUInt32(at: index * stride) }
    }

    func int32(at index: Int) -> Int32 {
        return Int32(bitPattern: uint32(at: index))
    }

    func float32(at index: Int) -> Float {
        return Float(bitPattern: uint32(at: index))
    }

    func uint64(at index: Int) -> UInt64 {
        precondition(stride == 8 && index >= 0 && index < count)
        return withSpan { $0.readUInt64(at: index * stride) }
    }
}

extension UnsafeMutableRawBufferPointer {
    /// Byte stores support packed fields whose offsets are not naturally aligned.
    func writeLittleEndian<T: FixedWidthInteger>(_ value: T, at offset: Int) {
        let width = T.bitWidth / 8
        precondition(offset >= 0 && offset <= count && width <= count - offset)
        for byte in 0..<width {
            self[offset + byte] = UInt8(truncatingIfNeeded: value >> (byte * 8))
        }
    }
}

extension MappedBytes {
    func containsRange(offset: Int, length: Int) -> Bool {
        span.containsRange(offset: offset, length: length)
    }

    func readUInt16(at offset: Int) -> UInt16 { span.readUInt16(at: offset) }
    func readUInt32(at offset: Int) -> UInt32 { span.readUInt32(at: offset) }
    func readUInt64(at offset: Int) -> UInt64 { span.readUInt64(at: offset) }
}

extension UnsafeRawBufferPointer {
    @inline(__always)
    func containsRange(offset: Int, length: Int) -> Bool {
        offset >= 0 && length >= 0 && offset <= count && length <= count - offset
    }
    @inline(__always)
    func readUInt16(at offset: Int) -> UInt16 {
        precondition(offset >= 0 && offset + 2 <= count)
        return UInt16(
            littleEndian: loadUnaligned(
                fromByteOffset: offset,
                as: UInt16.self
            )
        )
    }

    @inline(__always)
    func readUInt32(at offset: Int) -> UInt32 {
        precondition(offset >= 0 && offset + 4 <= count)
        return UInt32(
            littleEndian: loadUnaligned(
                fromByteOffset: offset,
                as: UInt32.self
            )
        )
    }

    @inline(__always)
    func readUInt64(at offset: Int) -> UInt64 {
        precondition(offset >= 0 && offset + 8 <= count)
        return UInt64(
            littleEndian: loadUnaligned(
                fromByteOffset: offset,
                as: UInt64.self
            )
        )
    }
}

extension Span where Element == UInt8 {
    func containsRange(offset: Int, length: Int) -> Bool {
        offset >= 0 && length >= 0 && offset <= count && length <= count - offset
    }

    func decodedUTF8() -> String? {
        withUnsafeBufferPointer { String(bytes: $0, encoding: .utf8) }
    }

    @inline(__always)
    func readUInt16(at offset: Int) -> UInt16 {
        precondition(offset >= 0 && offset + 2 <= count)
        return withUnsafeBufferPointer {
            UInt16(
                littleEndian: UnsafeRawBufferPointer($0).loadUnaligned(
                    fromByteOffset: offset,
                    as: UInt16.self
                )
            )
        }
    }

    @inline(__always)
    func readUInt32(at offset: Int) -> UInt32 {
        precondition(offset >= 0 && offset + 4 <= count)
        return withUnsafeBufferPointer {
            UInt32(
                littleEndian: UnsafeRawBufferPointer($0).loadUnaligned(
                    fromByteOffset: offset,
                    as: UInt32.self
                )
            )
        }
    }

    @inline(__always)
    func readUInt64(at offset: Int) -> UInt64 {
        precondition(offset >= 0 && offset + 8 <= count)
        return withUnsafeBufferPointer {
            UInt64(
                littleEndian: UnsafeRawBufferPointer($0).loadUnaligned(
                    fromByteOffset: offset,
                    as: UInt64.self
                )
            )
        }
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
