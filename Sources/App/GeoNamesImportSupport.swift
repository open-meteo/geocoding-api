import Foundation

enum GeoNamesImportError: Error, CustomStringConvertible {
    case missingField(file: String, line: Int, field: Int)
    case invalidInteger(file: String, line: Int, field: Int)
    case invalidFloat(file: String, line: Int, field: Int)
    case identifierOutOfRange(file: String, line: Int)
    case tooManyLanguages
    case tooManyValues(String)
    case invalidUTF8(file: String, line: Int, field: Int)

    var description: String {
        switch self {
        case .missingField(let file, let line, let field):
            return "\(file):\(line): missing tab-separated field \(field)"
        case .invalidInteger(let file, let line, let field):
            return "\(file):\(line): invalid integer in field \(field)"
        case .invalidFloat(let file, let line, let field):
            return "\(file):\(line): invalid floating point value in field \(field)"
        case .identifierOutOfRange(let file, let line):
            return "\(file):\(line): geoname identifier is outside UInt32 range"
        case .tooManyLanguages:
            return "The source contains more than 65,535 language identifiers."
        case .tooManyValues(let name):
            return "The source contains too many \(name) values for the database format."
        case .invalidUTF8(let file, let line, let field):
            return "\(file):\(line): invalid UTF-8 in field \(field)"
        }
    }
}

struct TSVLineScanner {
    let line: UnsafeRawBufferPointer
    private(set) var offset = 0
    private(set) var fieldNumber = 0

    init(_ line: UnsafeRawBufferPointer) {
        self.line = line
    }

    mutating func next(file: String, lineNumber: Int) throws -> UnsafeRawBufferPointer {
        fieldNumber += 1
        guard offset <= line.count else {
            throw GeoNamesImportError.missingField(
                file: file,
                line: lineNumber,
                field: fieldNumber
            )
        }
        let start = offset
        while offset < line.count, line[offset] != 9 {
            offset += 1
        }
        let result = UnsafeRawBufferPointer(rebasing: line[start..<offset])
        if offset < line.count {
            offset += 1
        } else {
            offset = line.count + 1
        }
        return result
    }

    mutating func skip(_ count: Int, file: String, lineNumber: Int) throws {
        for _ in 0..<count {
            _ = try next(file: file, lineNumber: lineNumber)
        }
    }
}

extension UnsafeRawBufferPointer {
    var packedASCII: UInt64? {
        guard count <= 8 else {
            return nil
        }
        var result: UInt64 = 0
        for (index, byte) in enumerated() {
            guard byte < 128 else {
                return nil
            }
            result |= UInt64(byte) << UInt64(index * 8)
        }
        return result
    }

    func equalsASCII(_ value: StaticString) -> Bool {
        guard count == value.utf8CodeUnitCount else {
            return false
        }
        return value.withUTF8Buffer { expected in
            elementsEqual(expected)
        }
    }

    var unsignedInteger: UInt32? {
        guard !isEmpty else {
            return nil
        }
        var result: UInt32 = 0
        for byte in self {
            guard byte >= 48, byte <= 57 else {
                return nil
            }
            let (multiplied, multiplicationOverflow) = result.multipliedReportingOverflow(by: 10)
            let (added, additionOverflow) = multiplied.addingReportingOverflow(UInt32(byte - 48))
            guard !multiplicationOverflow, !additionOverflow else {
                return nil
            }
            result = added
        }
        return result
    }

    var signedInteger: Int32? {
        guard !isEmpty else {
            return nil
        }
        var index = 0
        var isNegative = false
        if self[0] == 45 {
            isNegative = true
            index = 1
        }
        guard index < count else {
            return nil
        }
        var result: Int64 = 0
        while index < count {
            let byte = self[index]
            guard byte >= 48, byte <= 57 else {
                return nil
            }
            result = result * 10 + Int64(byte - 48)
            index += 1
        }
        if isNegative {
            result = -result
        }
        return Int32(exactly: result)
    }

    var signedInt16: Int16? {
        guard let value = signedInteger else {
            return nil
        }
        return Int16(exactly: value)
    }

    var decimalFloat: Float? {
        guard !isEmpty else {
            return nil
        }
        var index = 0
        var sign: Float = 1
        if self[index] == 45 {
            sign = -1
            index += 1
        } else if self[index] == 43 {
            index += 1
        }
        guard index < count else {
            return nil
        }

        var value: Double = 0
        var hasDigit = false
        while index < count {
            let byte = self[index]
            guard byte >= 48, byte <= 57 else {
                break
            }
            hasDigit = true
            value = value * 10 + Double(byte - 48)
            index += 1
        }
        if index < count, self[index] == 46 {
            index += 1
            var scale = 0.1
            while index < count {
                let byte = self[index]
                guard byte >= 48, byte <= 57 else {
                    break
                }
                hasDigit = true
                value += Double(byte - 48) * scale
                scale *= 0.1
                index += 1
            }
        }
        guard hasDigit else {
            return nil
        }
        if index < count, self[index] == 101 || self[index] == 69 {
            index += 1
            var exponentSign = 1
            if index < count, self[index] == 45 {
                exponentSign = -1
                index += 1
            } else if index < count, self[index] == 43 {
                index += 1
            }
            guard index < count else {
                return nil
            }
            var exponent = 0
            var exponentDigits = false
            while index < count {
                let byte = self[index]
                guard byte >= 48, byte <= 57 else {
                    return nil
                }
                exponentDigits = true
                exponent = exponent * 10 + Int(byte - 48)
                index += 1
            }
            guard exponentDigits else {
                return nil
            }
            value *= pow(10, Double(exponent * exponentSign))
        }
        guard index == count else {
            return nil
        }
        return Float(value) * sign
    }

    var iso2: UInt16 {
        guard count == 2 else {
            return 0
        }
        let first = self[0]
        let second = self[1]
        guard first < 128, second < 128 else {
            return 0
        }
        return UInt16(first) | (UInt16(second) << 8)
    }

    func copiedData() -> Data {
        return Data(self)
    }

    func utf8String(file: String, line: Int, field: Int) throws -> String {
        guard let value = String(bytes: self, encoding: .utf8) else {
            throw GeoNamesImportError.invalidUTF8(file: file, line: line, field: field)
        }
        return value
    }
}

struct DynamicBitSet {
    private(set) var words = [UInt64]()

    mutating func insert(_ value: UInt32) {
        let word = Int(value / 64)
        if word >= words.count {
            words.append(contentsOf: repeatElement(0, count: word - words.count + 1))
        }
        words[word] |= UInt64(1) << UInt64(value % 64)
    }

    func contains(_ value: UInt32) -> Bool {
        let word = Int(value / 64)
        guard word < words.count else {
            return false
        }
        return words[word] & (UInt64(1) << UInt64(value % 64)) != 0
    }
}

enum GeoNamesRecordRules {
    static let includedFeatureNames = [
        "ADM1", "ADM2", "ADM3", "ADM4", "ADM5", "PCLI", "PCLD", "PCLIX", "PCLS", "PCLF", "PCL",
        "PPL", "PPLL", "PPLC", "PPLA", "PPLA2", "PPLA3", "PPLA4", "PPLX", "PPLS", "PPLCH", "PPLG",
        "AMUS", "AIRP", "MT", "MTS", "PK", "PKS", "PAN", "PANS", "PASS", "VALL", "VALX", "VALG",
        "VALS", "FLLS", "DAM", "PRK", "GLCR", "CONT", "UPLD", "ISL", "ISLET", "ISLF", "ISLM",
        "ISLS", "ISLT", "CAPE", "AIRF", "AIRB", "AIRH",
    ].sorted()

    static let indexedFeatureNamesExcluded = Set([
        "PCL", "ADM1", "ADM2", "ADM3", "ADM4", "ADM5", "LTER", "PRSH", "TERR", "ZN", "ZNB",
    ])

    static let includedFeatureCodes: Set<UInt64> = Set(
        includedFeatureNames.compactMap {
            $0.utf8.withContiguousStorageIfAvailable { bytes in
                bytes.withUnsafeBytes { $0.packedASCII }
            } ?? nil
        }
    )

    static let featureIndexByCode: [UInt64: UInt8] = {
        var result = [UInt64: UInt8]()
        for (index, name) in includedFeatureNames.enumerated() {
            let code = name.utf8.withContiguousStorageIfAvailable { bytes in
                bytes.withUnsafeBytes { $0.packedASCII! }
            }!
            result[code] = UInt8(index)
        }
        return result
    }()

    static let searchExcludedFeatureIndexes: Set<UInt8> = Set(
        indexedFeatureNamesExcluded.compactMap { name in
            guard
                let code = name.utf8.withContiguousStorageIfAvailable({
                    $0.withUnsafeBytes { $0.packedASCII }
                }) ?? nil
            else {
                return nil
            }
            return featureIndexByCode[code]
        }
    )

    static func includes(_ feature: UnsafeRawBufferPointer) -> Bool {
        guard let code = feature.packedASCII else {
            return false
        }
        return includedFeatureCodes.contains(code)
    }

    static func featureIndex(_ feature: UnsafeRawBufferPointer) -> UInt8? {
        guard let code = feature.packedASCII else {
            return nil
        }
        return featureIndexByCode[code]
    }

    static func includeInSearchIndex(featureIndex: UInt8) -> Bool {
        return !searchExcludedFeatureIndexes.contains(featureIndex)
    }

    static func populationRank(_ population: UInt32) -> Float {
        guard population > 0 else {
            return 0
        }
        let exponent = -Float(population) / 50_000
        return 1 / (1 + 25 * expf(exponent))
    }

    static func ranking(
        population: UInt32,
        feature: UnsafeRawBufferPointer,
        hasPostcode: Bool
    ) -> Float {
        var result = populationRank(population)
        if hasPostcode {
            result += 0.1
        }
        if feature.equalsASCII("PPL") {
            result += 0.1
        } else if feature.equalsASCII("PPLA") || feature.equalsASCII("PPLC") {
            result += 0.3
        } else if feature.equalsASCII("PPLA2") {
            result += 0.23
        } else if feature.equalsASCII("PPLA3") {
            result += 0.2
        } else if feature.equalsASCII("PPLA4") {
            result += 0.18
        } else if feature.equalsASCII("PPLA5") {
            result += 0.15
        }
        return result
    }
}

final class ByteStringInterner {
    private(set) var strings = [String]()
    private var idsByHash = [UInt64: [UInt16]]()

    func findOrInsert(
        _ bytes: UnsafeRawBufferPointer,
        file: String,
        line: Int,
        field: Int
    ) throws -> UInt16 {
        let hash = Self.hash(bytes)
        if let candidates = idsByHash[hash] {
            for candidate in candidates {
                if strings[Int(candidate)].utf8.elementsEqual(bytes) {
                    return candidate
                }
            }
        }
        guard strings.count < Int(UInt16.max) else {
            throw GeoNamesImportError.tooManyLanguages
        }
        let value = try bytes.utf8String(file: file, line: line, field: field)
        let id = UInt16(strings.count)
        strings.append(value)
        idsByHash[hash, default: []].append(id)
        return id
    }

    func firstIndex(of value: String) -> UInt16? {
        return strings.firstIndex(of: value).map(UInt16.init)
    }

    private static func hash(_ bytes: UnsafeRawBufferPointer) -> UInt64 {
        var value: UInt64 = 14_695_981_039_346_656_037
        for byte in bytes {
            value ^= UInt64(byte)
            value &*= 1_099_511_628_211
        }
        return value
    }
}

private struct AdminCodeEntry {
    let country: UInt16
    let codes: [Data]
    let geonameID: Int32

    func matches(country: UInt16, codes: [UnsafeRawBufferPointer]) -> Bool {
        guard self.country == country, self.codes.count == codes.count else {
            return false
        }
        for index in codes.indices where !self.codes[index].elementsEqual(codes[index]) {
            return false
        }
        return true
    }
}

struct AdminCodeLookup {
    private var levels = [[UInt64: [AdminCodeEntry]]](repeating: [:], count: 4)

    mutating func insert(
        level: Int,
        country: UInt16,
        codes: [UnsafeRawBufferPointer],
        geonameID: Int32
    ) {
        let relevant = Array(codes.prefix(level + 1))
        let hash = Self.hash(country: country, codes: relevant)
        let entry = AdminCodeEntry(
            country: country,
            codes: relevant.map { $0.copiedData() },
            geonameID: geonameID
        )
        levels[level][hash, default: []].append(entry)
    }

    func find(
        level: Int,
        country: UInt16,
        codes: [UnsafeRawBufferPointer]
    ) -> Int32 {
        let relevant = Array(codes.prefix(level + 1))
        let hash = Self.hash(country: country, codes: relevant)
        return levels[level][hash]?.first {
            $0.matches(country: country, codes: relevant)
        }?.geonameID ?? 0
    }

    private static func hash(
        country: UInt16,
        codes: [UnsafeRawBufferPointer]
    ) -> UInt64 {
        var value: UInt64 = 14_695_981_039_346_656_037
        value ^= UInt64(country)
        value &*= 1_099_511_628_211
        for code in codes {
            value ^= 255
            value &*= 1_099_511_628_211
            for byte in code {
                value ^= UInt64(byte)
                value &*= 1_099_511_628_211
            }
        }
        return value
    }
}

extension Data {
    fileprivate func elementsEqual(_ other: UnsafeRawBufferPointer) -> Bool {
        guard count == other.count else {
            return false
        }
        return withUnsafeBytes { bytes in
            bytes.elementsEqual(other)
        }
    }
}
