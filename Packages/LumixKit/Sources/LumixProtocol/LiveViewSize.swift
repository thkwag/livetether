import Foundation

/// One live-view stream size the camera offers or uses.
///
/// Wire layout of an entry (little-endian): `u16 height | u16 width | u16 opaqueValue | u16 framesPerSecond`.
public struct LiveViewSize: Hashable, Sendable, Codable, CustomStringConvertible {
    public static let entryLength = 8

    public var width: UInt16
    public var height: UInt16
    /// A field whose meaning has not been established; it is echoed back to the camera unchanged.
    public var opaqueValue: UInt16
    public var framesPerSecond: UInt16

    public init(width: UInt16, height: UInt16, opaqueValue: UInt16, framesPerSecond: UInt16) {
        self.width = width
        self.height = height
        self.opaqueValue = opaqueValue
        self.framesPerSecond = framesPerSecond
    }

    public var description: String { "\(width)×\(height)@\(framesPerSecond)" }

    /// Decodes the reply to `0x9414` with parameter `0x0D800012`: `u16 count | u16 entryLength | entry[count]`.
    public static func decodeList(from block: Data) throws(ProtocolError) -> [LiveViewSize] {
        let payload = try payload(of: PanasonicValue.liveViewSizeList, in: block)
        var reader = ByteReader(payload)
        let count = Int(try reader.readUInt16())
        let declaredEntryLength = try reader.readUInt16()
        guard Int(declaredEntryLength) == entryLength else {
            throw .unexpectedEntryLength(declaredEntryLength)
        }
        guard 4 + count * entryLength <= payload.count else {
            throw .entriesExceedRecord(count: count, recordLength: payload.count)
        }
        var sizes: [LiveViewSize] = []
        sizes.reserveCapacity(count)
        for _ in 0..<count {
            sizes.append(try readEntry(&reader))
        }
        return sizes
    }

    /// Decodes the reply to `0x9414` with parameter `0x0D800011`: one entry.
    public static func decodeCurrent(from block: Data) throws(ProtocolError) -> LiveViewSize {
        let payload = try payload(of: PanasonicValue.liveViewCurrentSize, in: block)
        var reader = ByteReader(payload)
        return try readEntry(&reader)
    }

    /// The 16-byte data block of `0x9415`: `u32 0x0D800011 | u32 8 | entry`.
    public func setPropertyBlock() -> Data {
        var writer = ByteWriter()
        writer.write(PanasonicValue.liveViewCurrentSize)
        writer.write(UInt32(Self.entryLength))
        writer.write(height)
        writer.write(width)
        writer.write(opaqueValue)
        writer.write(framesPerSecond)
        return writer.data
    }

    /// The automatic choice: among entries at `framesPerSecond`, the one whose
    /// `width << 16 | height` is largest, keeping the first of equal entries; `nil` when none matches.
    public static func preferred(in sizes: [LiveViewSize], framesPerSecond: UInt16 = 30) -> LiveViewSize? {
        var best: LiveViewSize?
        for size in sizes where size.framesPerSecond == framesPerSecond {
            if let current = best, current.selectionKey >= size.selectionKey {
                continue
            }
            best = size
        }
        return best
    }

    private var selectionKey: UInt32 { UInt32(width) << 16 | UInt32(height) }

    private static func readEntry(_ reader: inout ByteReader) throws(ProtocolError) -> LiveViewSize {
        let height = try reader.readUInt16()
        let width = try reader.readUInt16()
        let opaqueValue = try reader.readUInt16()
        let framesPerSecond = try reader.readUInt16()
        return LiveViewSize(width: width, height: height, opaqueValue: opaqueValue, framesPerSecond: framesPerSecond)
    }

    private static func payload(of tag: UInt32, in block: Data) throws(ProtocolError) -> Data {
        let records = try TaggedRecords.parse(block)
        guard let record = records.first(where: { $0.tag == tag }) else {
            throw .missingRecord(tag: tag)
        }
        return record.payload
    }
}
