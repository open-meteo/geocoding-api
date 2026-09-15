import Foundation

/// Buffered, bounded reader for our temporary fixed-header binary records.
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

    /// The span is valid only during the callback. Use next() for merge heads
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

/// Bounded sort runs and a 32-way merge. One implementation serves alternate names,
/// search candidates, and area views; record codecs supply only a comparison.
enum ExternalSort {
    typealias Less = (UnsafeRawBufferPointer, UnsafeRawBufferPointer) -> Bool

    static func sort(
        inputs: [URL],
        workspace: URL,
        label: String,
        headerSize: Int,
        lengthOffset: Int? = nil,
        memoryBytes: Int,
        fanIn: Int = 32,
        less: Less
    ) throws -> URL {
        precondition((2...32).contains(fanIn))
        guard memoryBytes >= 8 << 20 else {
            throw DatabaseBuildIOError.write(
                path: workspace.path,
                message: "external sort requires at least 8 MiB working memory"
            )
        }
        // Reserve space for buffer growth, sorting scratch, the current input record,
        // and I/O buffers. A fixed fan-in alone doesn't bound long-record merges.
        let chunkBudget = (memoryBytes - (1 << 20)) / 3
        var maximumRecordBytes = headerSize
        var data = Data()
        var offsets = [Int]()
        var runs = [URL]()
        func flush() throws {
            guard !offsets.isEmpty else { return }
            data.withUnsafeBytes { bytes in
                offsets.sort { lhs, rhs in
                    let leftCount = headerSize + (lengthOffset.map { Int(bytes.readUInt32(at: lhs + $0)) } ?? 0)
                    let rightCount = headerSize + (lengthOffset.map { Int(bytes.readUInt32(at: rhs + $0)) } ?? 0)
                    return less(
                        UnsafeRawBufferPointer(rebasing: bytes[lhs..<lhs + leftCount]),
                        UnsafeRawBufferPointer(rebasing: bytes[rhs..<rhs + rightCount])
                    )
                }
            }
            let url = workspace.appendingPathComponent("\(label)-run-\(runs.count).tmp")
            let writer = try BufferedBinaryWriter(url: url)
            try data.withUnsafeBytes { bytes in
                for offset in offsets {
                    let count = headerSize + (lengthOffset.map { Int(bytes.readUInt32(at: offset + $0)) } ?? 0)
                    try writer.write(UnsafeRawBufferPointer(rebasing: bytes[offset..<offset + count]))
                }
            }
            _ = try writer.close()
            runs.append(url)
            data.removeAll(keepingCapacity: false)
            offsets.removeAll(keepingCapacity: false)
        }
        for input in inputs {
            let reader = try BinaryRecordReader(url: input, headerSize: headerSize, lengthOffset: lengthOffset)
            while try reader.withNextRecord({ record -> Void in
                maximumRecordBytes = max(maximumRecordBytes, record.count)
                let cost = data.count + record.count + (offsets.count + 1) * 16
                if cost > chunkBudget { try flush() }
                guard record.count + 16 <= chunkBudget else {
                    throw DatabaseBuildIOError.write(path: input.path, message: "sort record exceeds memory budget")
                }
                offsets.append(data.count)
                record.withUnsafeBufferPointer { data.append(contentsOf: $0) }
            }) != nil {}
        }
        try flush()
        let mergeCapacity =
            (memoryBytes - 2 * maximumRecordBytes - (64 << 10))
            / (2 * maximumRecordBytes + (64 << 10))
        guard runs.count <= 1 || mergeCapacity >= 2 else {
            throw DatabaseBuildIOError.write(
                path: workspace.path,
                message: "Merge needs at least \(6 * maximumRecordBytes + (192 << 10)) bytes for these records"
            )
        }
        let mergeFanIn = min(fanIn, max(2, mergeCapacity))
        var pass = 0
        while runs.count > 1 {
            var next = [URL]()
            for start in stride(from: 0, to: runs.count, by: mergeFanIn) {
                let batch = Array(runs[start..<min(start + mergeFanIn, runs.count)])
                let output = workspace.appendingPathComponent("\(label)-merge-\(pass)-\(start).tmp")
                try merge(inputs: batch, output: output, headerSize: headerSize, lengthOffset: lengthOffset, less: less)
                for input in batch { try FileManager.default.removeItem(at: input) }
                next.append(output)
            }
            runs = next
            pass += 1
        }
        if let result = runs.first { return result }
        let empty = workspace.appendingPathComponent("\(label)-empty.tmp")
        _ = try BufferedBinaryWriter(url: empty).close()
        return empty
    }

    private static func merge(
        inputs: [URL],
        output: URL,
        headerSize: Int,
        lengthOffset: Int?,
        less: Less
    ) throws {
        let readers = try inputs.map {
            try BinaryRecordReader(url: $0, headerSize: headerSize, lengthOffset: lengthOffset)
        }
        var records = try readers.map { try $0.next() }
        var heap = [Int]()
        func precedes(_ lhs: Int, _ rhs: Int) -> Bool {
            records[lhs]!.withUnsafeBytes { left in
                records[rhs]!.withUnsafeBytes { right in
                    if less(left, right) { return true }
                    if less(right, left) { return false }
                    return lhs < rhs
                }
            }
        }
        func insert(_ value: Int) {
            heap.append(value)
            var index = heap.count - 1
            while index > 0 {
                let parent = (index - 1) / 2
                if !precedes(heap[index], heap[parent]) { break }
                heap.swapAt(index, parent)
                index = parent
            }
        }
        func pop() -> Int? {
            guard let first = heap.first else { return nil }
            let last = heap.removeLast()
            if !heap.isEmpty {
                heap[0] = last
                var index = 0
                while index * 2 + 1 < heap.count {
                    var child = index * 2 + 1
                    if child + 1 < heap.count && precedes(heap[child + 1], heap[child]) { child += 1 }
                    if !precedes(heap[child], heap[index]) { break }
                    heap.swapAt(index, child)
                    index = child
                }
            }
            return first
        }
        for index in records.indices where records[index] != nil { insert(index) }
        let writer = try BufferedBinaryWriter(url: output)
        while let index = pop() {
            try writer.write(records[index]!)
            records[index] = try readers[index].next()
            if records[index] != nil { insert(index) }
        }
        _ = try writer.close()
    }
}
