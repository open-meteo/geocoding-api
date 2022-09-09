import Foundation


extension Data {    
    func forEachLine(_ fn: (UnsafeRawBufferPointer) -> ()) {
        var start = startIndex
        let nl = Character("\n").asciiValue!
        withUnsafeBytes { dataPtr in
            for i in dataPtr.indices {
                if self[i] == nl {
                    fn(UnsafeRawBufferPointer(rebasing: dataPtr[start..<i]))
                    start = i+1
                }
            }
            fn(UnsafeRawBufferPointer(rebasing: dataPtr[start..<endIndex]))
        }
    }
}

extension UnsafeRawBufferPointer {
    public var hashValue: Int {
        var hasher = Hasher()
        hasher.combine(bytes: self)
        return hasher.finalize()
    }
    
    func seekUntil(value: Element, offset: inout Int) -> UnsafeRawBufferPointer {
        for i in offset ..< endIndex {
            if self[i] == value {
                let ptr = UnsafeRawBufferPointer(rebasing: self[offset ..< i])
                offset = i+1
                return ptr
            }
        }
        fatalError()
    }
    
    func extendUntil(_ other: UnsafeRawBufferPointer) -> UnsafeRawBufferPointer {
        let end = other.baseAddress!.advanced(by: other.count)
        let count = self.baseAddress!.distance(to: end)
        return UnsafeRawBufferPointer(start: self.baseAddress, count: count)
    }
    
    var asciiToInt32: Int32 {
        let ascii0 = Character("0").asciiValue!
        var ret: Int32 = 0;
        for val in self {
            if val == 45 {
                ret = ret * -1
            } else {
                ret = ret * 10 + Int32(val - ascii0)
            }
        }
        return ret
    }
    
    var asciiToUInt32: UInt32 {
        let ascii0 = Character("0").asciiValue!
        var ret: UInt32 = 0;
        for val in self {
            if val == 45 {
                return 0
            } else {
                ret = ret * 10 + UInt32(val - ascii0)
            }
        }
        return ret
    }
    
    var asciiToInt16: Int16 {
        let ascii0 = Character("0").asciiValue!
        var ret: Int16 = 0;
        for val in self {
            if val == 45 {
                ret = ret * -1
            } else {
                ret = ret * 10 + Int16(val - ascii0)
            }
        }
        return ret
    }
    
    var asciiToInt8: Int8 {
        let ascii0 = Character("0").asciiValue!
        var ret: Int8 = 0;
        if self.count  > 2 {
            print(self.string)
        }
        for val in self {
            if val == 45 {
                ret = ret * -1
            } else {
                ret = ret * 10 + Int8(val - ascii0)
            }
        }
        return ret
    }
    
    /*var asciiToInt: Int64 {
        let ascii0 = Character("0").asciiValue!
        var ret: Int64 = 0;
        for val in self {
            if val == 45 {
                ret = ret * -1
            } else {
                ret = ret * 10 + Int64(val - ascii0)
            }
        }
        return ret
    }*/
    
    var float: Float {
        return Float(string) ?? .nan
    }
    
    var string: String {
        if isEmpty {
             return ""
        }
        /// Note: Although it says `bytesNoCopy` it will always copy data. This is nicest way to convert a pointer with a fixed length to a string
        guard let base = self.baseAddress, let s = String(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), length: count, encoding: .utf8, freeWhenDone: false) else {
            fatalError("String could not be converted")
        }
        return s
    }
}

extension Array {
    /// Create a unique array of a mapped result
    func unique<T: Comparable>(of fn: (Element) -> T) -> [T] {
        var mapped = self.map(fn)
        mapped.sort()
        
        guard var previous = mapped.first else {
            return []
        }
        var count = 1
        for value in mapped {
            if value != previous {
                count += 1
                previous = value
            }
        }
        
        var result = [T]()
        result.reserveCapacity(count)
        guard var previous = mapped.first else {
            return []
        }
        result.append(previous)
        for value in mapped {
            if value != previous {
                result.append(value)
                previous = value
            }
        }
        assert(count == result.count)
        return result
        
    }
}
