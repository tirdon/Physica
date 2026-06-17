// ByteReader — big-endian cursor over a [UInt8] buffer, the primitive every
// TrueType table parser reads through. See Font.swift.

// MARK: - Big-endian reader

struct ByteReader {
    let data: [UInt8]
    var offset: Int

    init(data: [UInt8], offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    mutating func skip(_ count: Int) {
        offset += count
    }

    mutating func u8() throws -> UInt8 {
        guard offset < data.count else { throw FontError.malformed("eof") }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func i8() throws -> Int8 {
        Int8(bitPattern: try u8())
    }

    mutating func u16() throws -> UInt16 {
        UInt16(try u8()) << 8 | UInt16(try u8())
    }

    mutating func i16() throws -> Int16 {
        Int16(bitPattern: try u16())
    }

    mutating func u32() throws -> UInt32 {
        UInt32(try u16()) << 16 | UInt32(try u16())
    }

    mutating func tag() throws -> String {
        let bytes = [try u8(), try u8(), try u8(), try u8()]
        return String(decoding: bytes, as: UTF8.self)
    }
}
