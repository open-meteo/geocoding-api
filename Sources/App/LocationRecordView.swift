import Foundation

/// Stable file layout; deliberately independent of Swift's native struct layout.
/// 0...47: twelve 32-bit values, 48...57: five 16-bit values,
/// 58: feature, 59...63: reserved zero bytes.
struct LocationRecordView {
    static let stride = LocationRecordLayout.stride
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
    var id: UInt32 { u32(LocationRecordLayout.id) }
    var latitude: Float { Float(bitPattern: u32(LocationRecordLayout.latitude)) }
    var longitude: Float { Float(bitPattern: u32(LocationRecordLayout.longitude)) }
    var population: UInt32 { u32(LocationRecordLayout.population) }
    var countryID: Int32 { Int32(bitPattern: u32(LocationRecordLayout.countryID)) }
    var admin1ID: Int32 { Int32(bitPattern: u32(LocationRecordLayout.admin1ID)) }
    var admin2ID: Int32 { Int32(bitPattern: u32(LocationRecordLayout.admin2ID)) }
    var admin3ID: Int32 { Int32(bitPattern: u32(LocationRecordLayout.admin3ID)) }
    var admin4ID: Int32 { Int32(bitPattern: u32(LocationRecordLayout.admin4ID)) }
    var nameOffset: UInt32 { u32(LocationRecordLayout.nameOffset) }
    var alternateStart: UInt32 { u32(LocationRecordLayout.alternateStart) }
    var postcodeStart: UInt32 { u32(LocationRecordLayout.postcodeStart) }
    var elevation: Int16 { Int16(bitPattern: u16(LocationRecordLayout.elevation)) }
    var timezone: UInt16 { u16(LocationRecordLayout.timezone) }
    var country: UInt16 { u16(LocationRecordLayout.country) }
    var alternateCount: UInt16 { u16(LocationRecordLayout.alternateCount) }
    var postcodeCount: UInt16 { u16(LocationRecordLayout.postcodeCount) }
    var feature: UInt8 { section.withSpan { $0[offset + LocationRecordLayout.feature] } }
    var reservedIsZero: Bool {
        section.withSpan { bytes in
            (LocationRecordLayout.reserved..<LocationRecordLayout.stride).allSatisfy { bytes[offset + $0] == 0 }
        }
    }
}
