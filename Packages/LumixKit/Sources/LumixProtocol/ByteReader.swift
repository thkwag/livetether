import Foundation

/// Reads little-endian integers and byte runs from a buffer and refuses to read past its end.
///
/// The reader works on any `Data`, including slices whose indices do not start at zero;
/// `offset` always counts from the first byte of the buffer it was given.
public struct ByteReader: Sendable {
    public let bytes: Data
    public private(set) var offset: Int

    public init(_ bytes: Data, offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    public var remaining: Int { max(0, bytes.count - offset) }

    public mutating func readUInt8() throws(ProtocolError) -> UInt8 {
        try require(1)
        let value = bytes[bytes.startIndex + offset]
        offset += 1
        return value
    }

    public mutating func readUInt16() throws(ProtocolError) -> UInt16 {
        try require(2)
        let base = bytes.startIndex + offset
        let value = UInt16(bytes[base]) | UInt16(bytes[base + 1]) << 8
        offset += 2
        return value
    }

    public mutating func readUInt32() throws(ProtocolError) -> UInt32 {
        try require(4)
        let base = bytes.startIndex + offset
        var value: UInt32 = 0
        for index in 0..<4 {
            value |= UInt32(bytes[base + index]) << (8 * UInt32(index))
        }
        offset += 4
        return value
    }

    /// Returns the next `count` bytes as a buffer whose indices start at zero.
    public mutating func readData(count: Int) throws(ProtocolError) -> Data {
        try require(count)
        let base = bytes.startIndex + offset
        let value = bytes.subdata(in: base..<(base + count))
        offset += count
        return value
    }

    public mutating func skip(_ count: Int) throws(ProtocolError) {
        try require(count)
        offset += count
    }

    private func require(_ count: Int) throws(ProtocolError) {
        guard count >= 0, offset >= 0, remaining >= count else {
            throw .truncated(offset: offset, needed: count, available: remaining)
        }
    }
}

/// Appends little-endian integers and byte runs to a growing buffer.
public struct ByteWriter: Sendable {
    public private(set) var data = Data()

    public init() {}

    public mutating func write(_ value: UInt16) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    public mutating func write(_ value: UInt32) {
        for index in 0..<4 {
            data.append(UInt8(truncatingIfNeeded: value >> (8 * UInt32(index))))
        }
    }

    public mutating func write(_ bytes: Data) {
        data.append(bytes)
    }
}
