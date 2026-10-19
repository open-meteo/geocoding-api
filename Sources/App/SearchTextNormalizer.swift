import Foundation

enum SearchTextNormalizer {
    static func foldAndLowercase(_ value: String) -> String {
        var ascii = true
        var needsNormalization = false
        for byte in value.utf8 {
            if byte >= 128 {
                ascii = false
                break
            }
            // Remember whether any byte is uppercase ASCII (A–Z: 65–90) or a hyphen (-: 45).
            needsNormalization = needsNormalization || (65...90).contains(byte) || byte == 45
        }
        if ascii {
            guard needsNormalization else {
                return value
            }
            var bytes = [UInt8]()
            bytes.reserveCapacity(value.utf8.count)
            for byte in value.utf8 {
                bytes.append(
                    byte == 45 ? 32 : ((65...90).contains(byte) ? byte + 32 : byte)
                )
            }
            return String(decoding: bytes, as: UTF8.self)
        }
        var folded =
            value
            .folding(options: .diacriticInsensitive, locale: nil)
            .lowercased()
        if !folded.utf8.allSatisfy({ $0 < 128 }) {
            // Letters such as ø and ł are not removed by diacritic folding.
            folded = folded.applyingTransform(StringTransform("Latin-ASCII"), reverse: false) ?? folded
        }
        if folded.unicodeScalars.contains(where: { $0.properties.generalCategory == .dashPunctuation }) {
            folded = String(String.UnicodeScalarView(folded.unicodeScalars.map {
                $0.properties.generalCategory == .dashPunctuation ? " " : $0
            }))
        }
        // Radix and alias lookups compare bytes, so all transformations must end in NFC.
        return folded.precomposedStringWithCanonicalMapping
    }
}
