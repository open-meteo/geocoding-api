import Foundation
import Testing

@testable import App

struct BinaryRecordLayoutTests {
    @Test(arguments: [1, 17, 65_536])
    func packedEncodingPreservesBytes(bufferCapacity: Int) throws {
        let fixture = try DatabaseFixture(count: 0)
        defer { fixture.remove() }
        let output = fixture.directory.appendingPathComponent("records")
        let writer = try BufferedBinaryWriter(url: output, capacity: bufferCapacity)
        try writer.write(UInt8(255))
        try writer.writeRecord(byteCount: 16) { bytes in
            bytes.writeLittleEndian(UInt8(1), at: 0)
            bytes.writeLittleEndian(Int16(-2), at: 1)
            bytes.writeLittleEndian(Float(-1.5).bitPattern, at: 3)
            bytes.writeLittleEndian(UInt64(0x0807_0605_0403_0201), at: 7)
        }
        _ = try writer.close()
        // Literal wire bytes test endianness, unaligned fields and zero padding.
        #expect(
            Array(try Data(contentsOf: output)) == [
                255, 1, 254, 255, 0, 0, 192, 191, 1, 2, 3, 4, 5, 6, 7, 8, 0,
            ]
        )
    }
}
