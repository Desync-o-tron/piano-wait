import Foundation

/// Bounds-checked big-endian reader over a byte array.
struct ByteReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    var isAtEnd: Bool { offset >= bytes.count }

    mutating func readByte() throws -> UInt8 {
        guard offset < bytes.count else { throw MIDIParseError.truncatedData }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, count <= bytes.count - offset else { throw MIDIParseError.truncatedData }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, count <= bytes.count - offset else { throw MIDIParseError.truncatedData }
        offset += count
    }

    mutating func skipToEnd() {
        offset = bytes.count
    }

    mutating func readUInt16() throws -> UInt16 {
        let high = try readByte()
        let low = try readByte()
        return UInt16(high) << 8 | UInt16(low)
    }

    mutating func readUInt32() throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            value = value << 8 | UInt32(try readByte())
        }
        return value
    }

    /// Reads an SMF variable-length quantity, which is at most four bytes long.
    mutating func readVariableLengthQuantity() throws -> Int {
        var value = 0
        for _ in 0..<4 {
            let byte = try readByte()
            value = value << 7 | Int(byte & 0x7F)
            if byte & 0x80 == 0 { return value }
        }
        throw MIDIParseError.invalidVariableLengthQuantity
    }
}
