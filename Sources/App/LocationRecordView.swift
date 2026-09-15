import Foundation

/// Stable file layout; deliberately independent of Swift's native struct layout.
/// 0...47: twelve 32-bit values, 48...57: five 16-bit values,
/// 58: feature, 59...63: reserved zero bytes.
struct LocationRecordView {
    static let stride = 64
    private let section: MappedDatabaseSection
    private let offset: Int

    init(section: MappedDatabaseSection, row: Int) {
        precondition(section.stride == Self.stride && row >= 0 && row < section.count)
        self.section = section
        offset = row * Self.stride
    }

    private func u32(_ field: Int) -> UInt32 {
        section.withSpan { $0.readUInt32(at: offset + field) }
    }
    private func u16(_ field: Int) -> UInt16 {
        section.withSpan { $0.readUInt16(at: offset + field) }
    }
    var id: UInt32 { u32(0) }
    var latitude: Float { Float(bitPattern: u32(4)) }
    var longitude: Float { Float(bitPattern: u32(8)) }
    var population: UInt32 { u32(12) }
    var countryID: Int32 { Int32(bitPattern: u32(16)) }
    var admin1ID: Int32 { Int32(bitPattern: u32(20)) }
    var admin2ID: Int32 { Int32(bitPattern: u32(24)) }
    var admin3ID: Int32 { Int32(bitPattern: u32(28)) }
    var admin4ID: Int32 { Int32(bitPattern: u32(32)) }
    var nameOffset: UInt32 { u32(36) }
    var alternateStart: UInt32 { u32(40) }
    var postcodeStart: UInt32 { u32(44) }
    var elevation: Int16 { Int16(bitPattern: u16(48)) }
    var timezone: UInt16 { u16(50) }
    var country: UInt16 { u16(52) }
    var alternateCount: UInt16 { u16(54) }
    var postcodeCount: UInt16 { u16(56) }
    var feature: UInt8 { section.withSpan { $0[offset + 58] } }
    var reservedIsZero: Bool {
        section.withSpan { bytes in (59..<64).allSatisfy { bytes[offset + $0] == 0 } }
    }
}
