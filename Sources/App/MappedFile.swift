import Foundation

#if os(Linux)
import Glibc
#else
import Darwin
#endif

enum MappedFileError: Error, CustomStringConvertible {
    case open(path: String, message: String)
    case stat(path: String, message: String)
    case empty(path: String)
    case map(path: String, message: String)
    case range(offset: UInt64, length: UInt64, fileSize: Int)

    var description: String {
        switch self {
        case .open(let path, let message):
            return "Could not open \(path): \(message)"
        case .stat(let path, let message):
            return "Could not inspect \(path): \(message)"
        case .empty(let path):
            return "Cannot memory-map empty file \(path)"
        case .map(let path, let message):
            return "Could not memory-map \(path): \(message)"
        case .range(let offset, let length, let fileSize):
            return "Mapped range \(offset)..<\(offset + length) exceeds file size \(fileSize)"
        }
    }
}

/// Owns an immutable, private memory mapping for the lifetime of the database.
final class MappedFile: @unchecked Sendable {
    let path: String
    let count: Int
    private let descriptor: Int32
    private let address: UnsafeMutableRawPointer

    init(url: URL) throws {
        path = url.path
        descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else {
            throw MappedFileError.open(path: path, message: Self.lastError())
        }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let message = Self.lastError()
            close(descriptor)
            throw MappedFileError.stat(path: path, message: message)
        }
        guard info.st_size > 0, let size = Int(exactly: info.st_size) else {
            close(descriptor)
            throw MappedFileError.empty(path: path)
        }
        count = size

        guard
            let mapping = mmap(nil, count, PROT_READ, MAP_PRIVATE, descriptor, 0),
            mapping != MAP_FAILED
        else {
            let message = Self.lastError()
            close(descriptor)
            throw MappedFileError.map(path: path, message: message)
        }
        address = mapping
    }

    deinit {
        _ = munmap(address, count)
        _ = close(descriptor)
    }

    func bytes(offset: UInt64, length: UInt64) throws -> UnsafeRawBufferPointer {
        guard
            offset <= UInt64(count),
            length <= UInt64(count) - offset,
            let integerOffset = Int(exactly: offset),
            let integerLength = Int(exactly: length)
        else {
            throw MappedFileError.range(offset: offset, length: length, fileSize: count)
        }
        return UnsafeRawBufferPointer(
            start: UnsafeRawPointer(address).advanced(by: integerOffset),
            count: integerLength
        )
    }

    private static func lastError() -> String {
        return String(cString: strerror(errno))
    }
}
