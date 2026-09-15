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

struct TSVFieldCursor {
    fileprivate var offset = 0
    fileprivate var fieldNumber = 0
}

struct TSVLineScanner: ~Escapable {
    private let line: Span<UInt8>

    @_lifetime(copy line)
    init(_ line: consuming Span<UInt8>) {
        self.line = line
    }

    @_lifetime(borrow self)
    borrowing func next(
        _ cursor: inout TSVFieldCursor,
        file: String,
        lineNumber: Int
    ) throws -> Span<UInt8> {
        cursor.fieldNumber += 1
        guard cursor.offset <= line.count else {
            throw GeoNamesImportError.missingField(
                file: file,
                line: lineNumber,
                field: cursor.fieldNumber
            )
        }
        let start = cursor.offset
        while cursor.offset < line.count, line[cursor.offset] != 9 {
            cursor.offset += 1
        }
        let result = line.extracting(start..<cursor.offset)
        if cursor.offset < line.count {
            cursor.offset += 1
        } else {
            cursor.offset = line.count + 1
        }
        return result
    }

    borrowing func skip(
        _ cursor: inout TSVFieldCursor,
        _ count: Int,
        file: String,
        lineNumber: Int
    ) throws {
        for _ in 0..<count {
            _ = try next(&cursor, file: file, lineNumber: lineNumber)
        }
    }
}

extension Span where Element == UInt8 {
    var packedASCII: UInt64? {
        guard count <= 8 else {
            return nil
        }
        var result: UInt64 = 0
        for index in indices {
            let byte = self[index]
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
            for index in indices where self[index] != expected[index] {
                return false
            }
            return true
        }
    }

    var unsignedInteger: UInt32? {
        guard !isEmpty else {
            return nil
        }
        var result: UInt32 = 0
        for index in indices {
            let byte = self[index]
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
        return withUnsafeBufferPointer { Data(buffer: $0) }
    }

    func utf8String(file: String, line: Int, field: Int) throws -> String {
        let value = withUnsafeBufferPointer {
            String(bytes: $0, encoding: .utf8)
        }
        guard let value else {
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
    private static let countryFeatureIndexes = Set(
        includedFeatureNames.enumerated().compactMap { index, name in
            switch name {
            case "PCLI", "PCLD", "PCLIX", "PCLS", "PCLF", "PCL":
                return UInt8(index)
            default:
                return nil
            }
        }
    )

    static let includedFeatureCodes: Set<UInt64> = Set(
        includedFeatureNames.compactMap {
            $0.utf8.withContiguousStorageIfAvailable { bytes in
                Span(_unsafeElements: bytes).packedASCII
            } ?? nil
        }
    )

    static let featureIndexByCode: [UInt64: UInt8] = {
        var result = [UInt64: UInt8]()
        for (index, name) in includedFeatureNames.enumerated() {
            let code = name.utf8.withContiguousStorageIfAvailable { bytes in
                Span(_unsafeElements: bytes).packedASCII!
            }!
            result[code] = UInt8(index)
        }
        return result
    }()

    static let searchExcludedFeatureIndexes: Set<UInt8> = Set(
        indexedFeatureNamesExcluded.compactMap { name in
            guard
                let code = name.utf8.withContiguousStorageIfAvailable({
                    Span(_unsafeElements: $0).packedASCII
                }) ?? nil
            else {
                return nil
            }
            return featureIndexByCode[code]
        }
    )

    static func includes(_ feature: borrowing Span<UInt8>) -> Bool {
        guard let code = feature.packedASCII else {
            return false
        }
        return includedFeatureCodes.contains(code)
    }

    static func featureIndex(_ feature: borrowing Span<UInt8>) -> UInt8? {
        guard let code = feature.packedASCII else {
            return nil
        }
        return featureIndexByCode[code]
    }

    static func includeInSearchIndex(featureIndex: UInt8) -> Bool {
        return !searchExcludedFeatureIndexes.contains(featureIndex)
    }

    static func isCountry(featureIndex: UInt8) -> Bool {
        return countryFeatureIndexes.contains(featureIndex)
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
        feature: borrowing Span<UInt8>,
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
        _ bytes: borrowing Span<UInt8>,
        file: String,
        line: Int,
        field: Int
    ) throws -> UInt16 {
        let hash = Self.hash(bytes)
        if let candidates = idsByHash[hash] {
            for candidate in candidates {
                if Self.equals(strings[Int(candidate)].utf8, bytes) {
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

    private static func hash(_ bytes: borrowing Span<UInt8>) -> UInt64 {
        var value: UInt64 = 14_695_981_039_346_656_037
        for index in bytes.indices {
            let byte = bytes[index]
            value ^= UInt64(byte)
            value &*= 1_099_511_628_211
        }
        return value
    }

    private static func equals(
        _ string: String.UTF8View,
        _ bytes: borrowing Span<UInt8>
    ) -> Bool {
        guard string.count == bytes.count else {
            return false
        }
        var index = 0
        for byte in string {
            guard byte == bytes[index] else {
                return false
            }
            index += 1
        }
        return true
    }
}

private struct AdminCodeEntry {
    let country: UInt16
    let codes: [Data]
    let geonameID: Int32

    func matches(
        country: UInt16,
        level: Int,
        code1: borrowing Span<UInt8>,
        code2: borrowing Span<UInt8>,
        code3: borrowing Span<UInt8>,
        code4: borrowing Span<UInt8>
    ) -> Bool {
        guard self.country == country, codes.count == level + 1 else {
            return false
        }
        for index in 0...level {
            let code: Span<UInt8>
            switch index {
            case 0: code = copy code1
            case 1: code = copy code2
            case 2: code = copy code3
            default: code = copy code4
            }
            guard codes[index].elementsEqual(code) else {
                return false
            }
        }
        return true
    }
}

struct AdminCodeLookup {
    private var levels = [[UInt64: [AdminCodeEntry]]](repeating: [:], count: 4)

    mutating func insert(
        level: Int,
        country: UInt16,
        code1: borrowing Span<UInt8>,
        code2: borrowing Span<UInt8>,
        code3: borrowing Span<UInt8>,
        code4: borrowing Span<UInt8>,
        geonameID: Int32
    ) {
        let hash = Self.hash(
            country: country,
            level: level,
            code1: code1,
            code2: code2,
            code3: code3,
            code4: code4
        )
        var storedCodes = [Data]()
        storedCodes.reserveCapacity(level + 1)
        storedCodes.append(code1.copiedData())
        if level >= 1 {
            storedCodes.append(code2.copiedData())
        }
        if level >= 2 {
            storedCodes.append(code3.copiedData())
        }
        if level >= 3 {
            storedCodes.append(code4.copiedData())
        }
        let entry = AdminCodeEntry(
            country: country,
            codes: storedCodes,
            geonameID: geonameID
        )
        levels[level][hash, default: []].append(entry)
    }

    func find(
        level: Int,
        country: UInt16,
        code1: borrowing Span<UInt8>,
        code2: borrowing Span<UInt8>,
        code3: borrowing Span<UInt8>,
        code4: borrowing Span<UInt8>
    ) -> Int32 {
        let hash = Self.hash(
            country: country,
            level: level,
            code1: code1,
            code2: code2,
            code3: code3,
            code4: code4
        )
        return levels[level][hash]?.first {
            $0.matches(
                country: country,
                level: level,
                code1: code1,
                code2: code2,
                code3: code3,
                code4: code4
            )
        }?.geonameID ?? 0
    }

    private static func hash(
        country: UInt16,
        level: Int,
        code1: borrowing Span<UInt8>,
        code2: borrowing Span<UInt8>,
        code3: borrowing Span<UInt8>,
        code4: borrowing Span<UInt8>
    ) -> UInt64 {
        var value: UInt64 = 14_695_981_039_346_656_037
        value ^= UInt64(country)
        value &*= 1_099_511_628_211
        for index in 0...level {
            let code: Span<UInt8>
            switch index {
            case 0: code = copy code1
            case 1: code = copy code2
            case 2: code = copy code3
            default: code = copy code4
            }
            value ^= 255
            value &*= 1_099_511_628_211
            for byteIndex in code.indices {
                let byte = code[byteIndex]
                value ^= UInt64(byte)
                value &*= 1_099_511_628_211
            }
        }
        return value
    }
}

extension Data {
    fileprivate func elementsEqual(
        _ other: borrowing Span<UInt8>
    ) -> Bool {
        guard count == other.count else {
            return false
        }
        return withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for index in other.indices where bytes[index] != other[index] {
                return false
            }
            return true
        }
    }
}
