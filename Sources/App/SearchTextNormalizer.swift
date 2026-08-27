import Foundation

enum SearchTextNormalizer {
    static func foldAndLowercase(_ value: String) -> String {
        var ascii = true
        var needsLowercasing = false
        for byte in value.utf8 {
            if byte >= 128 {
                ascii = false
                break
            }
            needsLowercasing = needsLowercasing || (65...90).contains(byte)
        }
        if ascii {
            guard needsLowercasing else {
                return value
            }
            var bytes = [UInt8]()
            bytes.reserveCapacity(value.utf8.count)
            for byte in value.utf8 {
                bytes.append(
                    (65...90).contains(byte) ? byte + 32 : byte
                )
            }
            return String(decoding: bytes, as: UTF8.self)
        }
        return
            value
            .folding(options: .diacriticInsensitive, locale: nil)
            .lowercased()
    }
}
