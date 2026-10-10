import Foundation

/// Tags of the records in a `0x9706` live-view data block.
public enum LiveViewFrameTag {
    public static let streamInfo: UInt32 = 0x1700_0000
    /// The `u32` at payload offset 4 is the JPEG start offset within the block.
    public static let jpegOffset: UInt32 = 0x1700_0001
    /// The `u32` at payload offset 4 is the JPEG size value.
    public static let jpegSize: UInt32 = 0x1700_0002
    public static let histogram: UInt32 = 0x1700_0003
    public static let posture: UInt32 = 0x1700_0004
    public static let level: UInt32 = 0x1700_0005
}

/// The JPEG image carried by one `0x9706` reply, and how it was located.
public struct LiveViewJPEG: Hashable, Sendable {
    public enum Extraction: Hashable, Sendable {
        /// Start and length both came from the offset and size records.
        case tagged
        /// The start came from the offset record; the end was found by scanning for the end-of-image marker.
        case taggedStartScannedEnd
        /// No usable records; the image was found by scanning for start- and end-of-image markers.
        case scanned
    }

    public let data: Data
    public let extraction: Extraction
}

/// Extracts the JPEG image from a `0x9706` live-view data block.
///
/// With start offset and size records, the image is
/// `block[offset ..< offset + min(count − offset, size − 12)]`. Public implementations disagree on the
/// block layout and the camera has not confirmed either, so every step that does not yield a well-formed JPEG falls back:
/// a tagged start whose slice lacks an end-of-image marker is extended to the first marker after it,
/// and a block without usable records is scanned for the first start-of-image marker and the first
/// end-of-image marker after it, as libgphoto2 does.
public enum LiveViewFrameParser {
    static let startOfImage: [UInt8] = [0xFF, 0xD8]
    static let endOfImage: [UInt8] = [0xFF, 0xD9]
    /// Subtracted from the size value to give the image length.
    static let sizeAdjustment = 12

    public static func extractJPEG(from block: Data) throws(ProtocolError) -> LiveViewJPEG {
        let bytes = [UInt8](block)
        if let tagged = taggedExtraction(bytes) {
            return tagged
        }
        guard let start = find(startOfImage, in: bytes, from: 0),
              let end = find(endOfImage, in: bytes, from: start + startOfImage.count) else {
            throw .noJPEG
        }
        return LiveViewJPEG(data: Data(bytes[start..<(end + endOfImage.count)]), extraction: .scanned)
    }

    private static func taggedExtraction(_ bytes: [UInt8]) -> LiveViewJPEG? {
        var jpegOffset: Int?
        var jpegSize: Int?
        for record in TaggedRecords.scan(Data(bytes)).records {
            switch record.tag {
            case LiveViewFrameTag.jpegOffset:
                jpegOffset = valueField(of: record)
            case LiveViewFrameTag.jpegSize:
                jpegSize = valueField(of: record)
            default:
                continue
            }
        }
        guard let start = jpegOffset, start >= 0, start < bytes.count,
              hasPrefix(startOfImage, in: bytes, at: start) else {
            return nil
        }
        if let size = jpegSize, size >= sizeAdjustment {
            let length = min(bytes.count - start, size - sizeAdjustment)
            let end = start + length
            if length >= startOfImage.count + endOfImage.count,
               hasPrefix(endOfImage, in: bytes, at: end - endOfImage.count) {
                return LiveViewJPEG(data: Data(bytes[start..<end]), extraction: .tagged)
            }
        }
        guard let end = find(endOfImage, in: bytes, from: start + startOfImage.count) else {
            return nil
        }
        return LiveViewJPEG(data: Data(bytes[start..<(end + endOfImage.count)]), extraction: .taggedStartScannedEnd)
    }

    /// The `u32` at payload offset 4 (record offset `+0xC`).
    private static func valueField(of record: TaggedRecord) -> Int? {
        var reader = ByteReader(record.payload)
        do {
            try reader.skip(4)
            return Int(try reader.readUInt32())
        } catch {
            return nil
        }
    }

    private static func hasPrefix(_ marker: [UInt8], in bytes: [UInt8], at index: Int) -> Bool {
        guard index >= 0, index + marker.count <= bytes.count else { return false }
        return bytes[index] == marker[0] && bytes[index + 1] == marker[1]
    }

    private static func find(_ marker: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
        guard start >= 0, bytes.count >= marker.count else { return nil }
        var index = start
        while index + marker.count <= bytes.count {
            if bytes[index] == marker[0] && bytes[index + 1] == marker[1] {
                return index
            }
            index += 1
        }
        return nil
    }
}
