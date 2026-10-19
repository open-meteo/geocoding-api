import Foundation

/// Buffered reader for our temporary fixed-header binary records.
final class BinaryRecordReader {
    let url: URL
    let headerSize: Int
    let lengthOffset: Int?
    private let handle: FileHandle
    private var buffer = Data()
    private var position = 0

    init(url: URL, headerSize: Int, lengthOffset: Int? = nil) throws {
        precondition(headerSize > 0)
        precondition(lengthOffset == nil || (lengthOffset! >= 0 && lengthOffset! + 4 <= headerSize))
        self.url = url
        self.headerSize = headerSize
        self.lengthOffset = lengthOffset
        handle = try FileHandle(forReadingFrom: url)
    }
    deinit { try? handle.close() }

    /// Keep complete records contiguous. Most records borrow the current buffer;
    /// only a refill copies an unconsumed tail across an I/O boundary.
    private func ensure(_ count: Int, allowEnd: Bool = false) throws -> Bool {
        if buffer.count - position >= count { return true }
        buffer = position == buffer.count ? Data() : Data(buffer[position...])
        position = 0
        while buffer.count < count {
            let chunk = try handle.read(upToCount: max(64 << 10, count - buffer.count)) ?? Data()
            guard !chunk.isEmpty else {
                if allowEnd && buffer.isEmpty { return false }
                throw DatabaseBuildIOError.read(path: url.path, message: "truncated sort record")
            }
            if buffer.isEmpty { buffer = chunk } else { buffer.append(chunk) }
        }
        return true
    }

    /// The span is valid only during the callback. Use next() for cursor records
    /// or other records that must remain owned after the reader advances.
    func withNextRecord<Result>(_ body: (borrowing Span<UInt8>) throws -> Result) throws -> Result? {
        guard try ensure(headerSize, allowEnd: true) else { return nil }
        var count = headerSize
        if let lengthOffset {
            let length = buffer.withUnsafeBytes { Int($0.readUInt32(at: position + lengthOffset)) }
            guard length <= 4 << 20 else {
                throw DatabaseBuildIOError.read(path: url.path, message: "temporary record exceeds 4 MiB")
            }
            count += length
            _ = try ensure(count)
        }
        defer { position += count }
        return try buffer.withUnsafeBytes { bytes in
            try body(Span(_unsafeBytes: UnsafeRawBufferPointer(rebasing: bytes[position..<position + count])))
        }
    }

    func next() throws -> Data? {
        try withNextRecord { record in
            record.withUnsafeBufferPointer { Data(buffer: $0) }
        }
    }

}

/// Sort offsets into a mapped input, then stream records to the output.
/// Payloads stay file-backed; only offsets and sorting scratch occupy heap memory.
enum MappedRecordSort {
    static func sort(
        input: URL,
        output: URL,
        headerSize: Int,
        lengthOffset: Int? = nil,
        less: (UnsafeRawBufferPointer, UnsafeRawBufferPointer) -> Bool
    ) throws -> URL {
        precondition(input != output)
        precondition(headerSize > 0)
        precondition(lengthOffset == nil || (lengthOffset! >= 0 && lengthOffset! + 4 <= headerSize))
        let mapping = try MappedFile(url: input)
        let mapped = try mapping.bytes(offset: 0, length: UInt64(mapping.count))
        try mapped.span.withUnsafeBufferPointer { buffer in
            let bytes = UnsafeRawBufferPointer(buffer)
            func recordSize(at offset: Int) -> Int {
                headerSize + (lengthOffset.map { Int(bytes.readUInt32(at: offset + $0)) } ?? 0)
            }
            // Int offsets support temporary files larger than 4 GiB on supported platforms.
            var offsets = [Int]()
            var position = 0
            while position < bytes.count {
                guard bytes.containsRange(offset: position, length: headerSize) else {
                    throw DatabaseBuildIOError.read(path: input.path, message: "truncated sort header")
                }
                let size = recordSize(at: position)
                guard size - headerSize <= 4 << 20,
                    bytes.containsRange(offset: position, length: size)
                else {
                    throw DatabaseBuildIOError.read(path: input.path, message: "invalid sort record length")
                }
                offsets.append(position)
                position += size
            }
            func record(at offset: Int) -> UnsafeRawBufferPointer {
                UnsafeRawBufferPointer(rebasing: bytes[offset..<offset + recordSize(at: offset)])
            }
            offsets.sort { less(record(at: $0), record(at: $1)) }
            let writer = try BufferedBinaryWriter(url: output)
            for offset in offsets { try writer.write(record(at: offset)) }
            _ = try writer.close()
        }
        return output
    }
}
