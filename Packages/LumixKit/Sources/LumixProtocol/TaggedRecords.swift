import Foundation

/// One record of a Panasonic data block: `u32 tag | u32 length | payload[length]`.
public struct TaggedRecord: Hashable, Sendable {
    /// Byte offset of the record header within the block.
    public let offset: Int
    public let tag: UInt32
    /// The payload, rebased so its indices start at zero.
    public let payload: Data
}

/// The records found by a lenient walk, and where the walk stopped if it met a malformed record.
public struct TaggedRecordScan: Sendable {
    public let records: [TaggedRecord]
    /// Offset of the first record that did not fit in the block, or `nil` when the walk consumed every byte.
    public let stoppedAt: Int?
}

/// Walks the tagged records of a Panasonic data block.
public enum TaggedRecords {
    public static let headerLength = 8

    /// Returns every record, or throws when a record declares more payload than the block holds.
    public static func parse(_ block: Data) throws(ProtocolError) -> [TaggedRecord] {
        var reader = ByteReader(block)
        var records: [TaggedRecord] = []
        while reader.remaining > 0 {
            records.append(try readRecord(&reader))
        }
        return records
    }

    /// Returns records up to the end of the block or up to the first record that does not fit.
    public static func scan(_ block: Data) -> TaggedRecordScan {
        var reader = ByteReader(block)
        var records: [TaggedRecord] = []
        while reader.remaining > 0 {
            let start = reader.offset
            do {
                records.append(try readRecord(&reader))
            } catch {
                return TaggedRecordScan(records: records, stoppedAt: start)
            }
        }
        return TaggedRecordScan(records: records, stoppedAt: nil)
    }

    private static func readRecord(_ reader: inout ByteReader) throws(ProtocolError) -> TaggedRecord {
        let start = reader.offset
        let tag = try reader.readUInt32()
        let length = try reader.readUInt32()
        guard UInt64(length) <= UInt64(reader.remaining) else {
            throw .recordOverrun(tag: tag, offset: start, declaredLength: length, available: reader.remaining)
        }
        let payload = try reader.readData(count: Int(length))
        return TaggedRecord(offset: start, tag: tag, payload: payload)
    }
}
