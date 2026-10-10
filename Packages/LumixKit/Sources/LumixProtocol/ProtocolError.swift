/// A failure to encode or decode a PTP container or a Panasonic data block.
public enum ProtocolError: Error, Equatable, Sendable {
    /// A read needed more bytes than the buffer holds.
    case truncated(offset: Int, needed: Int, available: Int)
    /// A PTP command carries at most five parameters.
    case tooManyParameters(Int)
    /// A container's byte count is outside the range its type allows.
    case containerLengthOutOfRange(Int)
    /// A container's length field disagrees with the number of bytes received.
    case containerLengthMismatch(declared: UInt32, actual: Int)
    /// A container carries a type other than the one expected.
    case unexpectedContainerType(UInt16)
    /// A tagged record declares more payload than the block holds.
    case recordOverrun(tag: UInt32, offset: Int, declaredLength: UInt32, available: Int)
    /// A block lacks the tagged record a decoder needs.
    case missingRecord(tag: UInt32)
    /// A live-view size list declares an entry length other than eight bytes.
    case unexpectedEntryLength(UInt16)
    /// A live-view size list declares more entries than its record holds.
    case entriesExceedRecord(count: Int, recordLength: Int)
    /// A live-view frame block holds no JPEG start-of-image marker followed by an end-of-image marker.
    case noJPEG
}
