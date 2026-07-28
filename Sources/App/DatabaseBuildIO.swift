import Foundation

#if os(Linux)
import Glibc
#else
import Darwin
#endif

enum DatabaseBuildIOError: Error, CustomStringConvertible {
    case open(path: String, message: String)
    case read(path: String, message: String)
    case write(path: String, message: String)
    case lineTooLong(path: String, length: Int)
    case closed(path: String)

    var description: String {
        switch self {
        case .open(let path, let message):
            return "Could not open \(path): \(message)"
        case .read(let path, let message):
            return "Could not read \(path): \(message)"
        case .write(let path, let message):
            return "Could not write \(path): \(message)"
        case .lineTooLong(let path, let length):
            return "Line in \(path) exceeds the supported size (\(length) bytes)."
        case .closed(let path):
            return "Writer for \(path) is already closed."
        }
    }
}

/// Incremental xxHash64 used for source fingerprints and database sections.
struct XXHash64 {
    private static let prime1: UInt64 = 11_400_714_785_074_694_791
    private static let prime2: UInt64 = 14_029_467_366_897_019_727
    private static let prime3: UInt64 = 1_609_587_929_392_839_161
    private static let prime4: UInt64 = 9_650_029_242_287_828_579
    private static let prime5: UInt64 = 2_870_177_450_012_600_261

    private var totalLength: UInt64 = 0
    private var accumulator1 = Self.prime1 &+ Self.prime2
    private var accumulator2 = Self.prime2
    private var accumulator3: UInt64 = 0
    private var accumulator4 = UInt64.max &- Self.prime1 &+ 1
    private var pending = [UInt8]()

    mutating func update(_ bytes: borrowing Span<UInt8>) {
        guard !bytes.isEmpty else {
            return
        }
        totalLength &+= UInt64(bytes.count)
        var offset = 0

        if !pending.isEmpty {
            let required = 32 - pending.count
            let copied = min(required, bytes.count)
            bytes.extracting(0..<copied).withUnsafeBufferPointer {
                pending.append(contentsOf: $0)
            }
            offset += copied
            if pending.count == 32 {
                pending.withUnsafeBufferPointer {
                    consumeStripe(Span(_unsafeElements: $0))
                }
                pending.removeAll(keepingCapacity: true)
            }
        }

        while offset + 32 <= bytes.count {
            consumeStripe(bytes.extracting(offset..<offset + 32))
            offset += 32
        }
        if offset < bytes.count {
            bytes.extracting(offset..<bytes.count).withUnsafeBufferPointer {
                pending.append(contentsOf: $0)
            }
        }
    }

    mutating func update(_ bytes: UnsafeRawBufferPointer) {
        update(Span<UInt8>(_unsafeBytes: bytes))
    }

    mutating func update(_ data: Data) {
        data.withUnsafeBytes { update($0) }
    }

    func digest() -> UInt64 {
        var hash: UInt64
        if totalLength >= 32 {
            hash =
                Self.rotateLeft(accumulator1, by: 1)
                &+ Self.rotateLeft(accumulator2, by: 7)
                &+ Self.rotateLeft(accumulator3, by: 12)
                &+ Self.rotateLeft(accumulator4, by: 18)
            hash = Self.mergeRound(hash, accumulator1)
            hash = Self.mergeRound(hash, accumulator2)
            hash = Self.mergeRound(hash, accumulator3)
            hash = Self.mergeRound(hash, accumulator4)
        } else {
            hash = Self.prime5
        }
        hash &+= totalLength

        pending.withUnsafeBytes { bytes in
            var offset = 0
            while offset + 8 <= bytes.count {
                let lane = bytes.readUInt64(at: offset)
                let mixed = Self.round(0, lane)
                hash ^= mixed
                hash = Self.rotateLeft(hash, by: 27) &* Self.prime1 &+ Self.prime4
                offset += 8
            }
            if offset + 4 <= bytes.count {
                hash ^= UInt64(bytes.readUInt32(at: offset)) &* Self.prime1
                hash = Self.rotateLeft(hash, by: 23) &* Self.prime2 &+ Self.prime3
                offset += 4
            }
            while offset < bytes.count {
                hash ^= UInt64(bytes[offset]) &* Self.prime5
                hash = Self.rotateLeft(hash, by: 11) &* Self.prime1
                offset += 1
            }
        }

        hash ^= hash >> 33
        hash &*= Self.prime2
        hash ^= hash >> 29
        hash &*= Self.prime3
        hash ^= hash >> 32
        return hash
    }

    private mutating func consumeStripe(_ bytes: borrowing Span<UInt8>) {
        accumulator1 = Self.round(accumulator1, bytes.readUInt64(at: 0))
        accumulator2 = Self.round(accumulator2, bytes.readUInt64(at: 8))
        accumulator3 = Self.round(accumulator3, bytes.readUInt64(at: 16))
        accumulator4 = Self.round(accumulator4, bytes.readUInt64(at: 24))
    }

    private static func round(_ accumulator: UInt64, _ lane: UInt64) -> UInt64 {
        var value = accumulator &+ lane &* prime2
        value = rotateLeft(value, by: 31)
        value &*= prime1
        return value
    }

    private static func mergeRound(_ hash: UInt64, _ accumulator: UInt64) -> UInt64 {
        var value = hash ^ round(0, accumulator)
        value = value &* prime1 &+ prime4
        return value
    }

    private static func rotateLeft(_ value: UInt64, by count: UInt64) -> UInt64 {
        return (value << count) | (value >> (64 - count))
    }
}

/// Reads newline-delimited input using bounded reusable storage.
final class BufferedLineReader {
    private static let maximumLineLength = 1 << 20

    let path: String
    private let descriptor: Int32
    private var buffer: [UInt8]

    init(url: URL, bufferSize: Int = 4 << 20) throws {
        precondition(bufferSize > 0)
        path = url.path
        descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else {
            throw DatabaseBuildIOError.open(path: path, message: Self.lastError())
        }
        buffer = [UInt8](repeating: 0, count: bufferSize)
    }

    deinit {
        _ = close(descriptor)
    }

    /// The borrowed line cannot escape the callback.
    func forEachLine(
        hasher: inout XXHash64,
        _ body: (borrowing Span<UInt8>) throws -> Void
    ) throws {
        var used = 0
        var reachedEnd = false

        while !reachedEnd {
            if used == buffer.count {
                guard buffer.count < Self.maximumLineLength else {
                    throw DatabaseBuildIOError.lineTooLong(path: path, length: used)
                }
                buffer.append(
                    contentsOf: repeatElement(
                        0,
                        count: min(buffer.count, Self.maximumLineLength - buffer.count)
                    )
                )
            }

            let bytesRead: Int = buffer.withUnsafeMutableBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else {
                    return 0
                }
                return read(
                    descriptor,
                    baseAddress.advanced(by: used),
                    rawBuffer.count - used
                )
            }
            guard bytesRead >= 0 else {
                throw DatabaseBuildIOError.read(path: path, message: Self.lastError())
            }
            reachedEnd = bytesRead == 0

            if bytesRead > 0 {
                buffer.withUnsafeBufferPointer { buffer in
                    let bytes = Span(_unsafeElements: buffer)
                    hasher.update(
                        bytes.extracting(used..<used + bytesRead)
                    )
                }
                used += bytesRead
            }

            var consumed = 0
            try buffer.withUnsafeBufferPointer { buffer in
                let bytes = Span(_unsafeElements: buffer)
                var lineStart = 0
                for index in 0..<used where bytes[index] == 10 {
                    try body(bytes.extracting(lineStart..<index))
                    lineStart = index + 1
                }
                consumed = lineStart
                if reachedEnd, lineStart < used {
                    try body(bytes.extracting(lineStart..<used))
                    consumed = used
                }
            }

            if consumed > 0, consumed < used {
                _ = buffer.withUnsafeMutableBytes { rawBuffer in
                    memmove(
                        rawBuffer.baseAddress!,
                        rawBuffer.baseAddress!.advanced(by: consumed),
                        used - consumed
                    )
                }
            }
            used -= consumed
        }
    }

    private static func lastError() -> String {
        return String(cString: strerror(errno))
    }
}

/// Buffered little-endian writer for temporary and final database sections.
final class BufferedBinaryWriter {
    let url: URL
    private let handle: FileHandle
    private var buffer = Data()
    private var hasher = XXHash64()
    private(set) var byteCount: UInt64 = 0
    private(set) var isClosed = false

    init(url: URL, capacity: Int = 1 << 20) throws {
        self.url = url
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw DatabaseBuildIOError.open(path: url.path, message: "createFile failed")
        }
        handle = try FileHandle(forWritingTo: url)
        buffer.reserveCapacity(capacity)
    }

    deinit {
        try? handle.close()
    }

    func write(_ value: UInt8) throws {
        buffer.append(value)
        try flushIfNeeded()
    }

    func write(_ value: UInt16) throws {
        buffer.append(UInt8(truncatingIfNeeded: value))
        buffer.append(UInt8(truncatingIfNeeded: value >> 8))
        try flushIfNeeded()
    }

    func write(_ value: Int16) throws {
        try write(UInt16(bitPattern: value))
    }

    func write(_ value: UInt32) throws {
        buffer.append(UInt8(truncatingIfNeeded: value))
        buffer.append(UInt8(truncatingIfNeeded: value >> 8))
        buffer.append(UInt8(truncatingIfNeeded: value >> 16))
        buffer.append(UInt8(truncatingIfNeeded: value >> 24))
        try flushIfNeeded()
    }

    func write(_ value: Int32) throws {
        try write(UInt32(bitPattern: value))
    }

    func write(_ value: UInt64) throws {
        try write(UInt32(truncatingIfNeeded: value))
        try write(UInt32(truncatingIfNeeded: value >> 32))
    }

    func write(_ value: Float) throws {
        try write(value.bitPattern)
    }

    func write(_ bytes: UnsafeRawBufferPointer) throws {
        buffer.append(contentsOf: bytes)
        try flushIfNeeded()
    }

    func write(_ bytes: borrowing Span<UInt8>) throws {
        try bytes.withUnsafeBufferPointer {
            try write(UnsafeRawBufferPointer($0))
        }
    }

    func write(_ data: Data) throws {
        buffer.append(data)
        try flushIfNeeded()
    }

    func writeLengthPrefixed(_ value: String) throws -> UInt32 {
        let offset = try currentUInt32Offset()
        let bytes = Array(value.utf8)
        try write(UInt32(bytes.count))
        try bytes.withUnsafeBytes { try write($0) }
        return offset
    }

    func currentUInt32Offset() throws -> UInt32 {
        let total = byteCount + UInt64(buffer.count)
        guard let offset = UInt32(exactly: total) else {
            throw DatabaseBuildIOError.write(
                path: url.path,
                message: "section exceeded 4 GiB"
            )
        }
        return offset
    }

    func close(synchronize: Bool = false) throws -> (length: UInt64, hash: UInt64) {
        guard !isClosed else {
            throw DatabaseBuildIOError.closed(path: url.path)
        }
        try flush()
        if synchronize {
            try handle.synchronize()
        }
        try handle.close()
        isClosed = true
        return (byteCount, hasher.digest())
    }

    private func flushIfNeeded() throws {
        if buffer.count >= 1 << 20 {
            try flush()
        }
    }

    private func flush() throws {
        guard !buffer.isEmpty else {
            return
        }
        do {
            try handle.write(contentsOf: buffer)
        } catch {
            throw DatabaseBuildIOError.write(path: url.path, message: "\(error)")
        }
        hasher.update(buffer)
        byteCount += UInt64(buffer.count)
        buffer.removeAll(keepingCapacity: true)
    }
}
