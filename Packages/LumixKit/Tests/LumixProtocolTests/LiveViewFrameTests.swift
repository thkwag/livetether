import Foundation
import LumixTestSupport
import Testing
@testable import LumixProtocol

@Suite("Live-view frame extraction")
struct LiveViewFrameTests {
    /// Bytes that carry no `0xFF`, so no marker can appear by accident.
    static func filler(_ generator: inout SeededGenerator, count: Int) -> [UInt8] {
        generator.bytes(count: count, excluding: [0xFF])
    }

    /// A JPEG-shaped byte run: start marker, marker-free body, end marker.
    static func jpeg(_ generator: inout SeededGenerator) -> [UInt8] {
        [0xFF, 0xD8] + filler(&generator, count: Int.random(in: 0...200, using: &generator)) + [0xFF, 0xD9]
    }

    static func record(tag: UInt32, payload: [UInt8]) -> [UInt8] {
        var writer = ByteWriter()
        writer.write(tag)
        writer.write(UInt32(payload.count))
        writer.write(Data(payload))
        return [UInt8](writer.data)
    }

    /// A value record: the value is the `u32` at payload offset 4.
    static func valueRecord(tag: UInt32, value: UInt32, _ generator: inout SeededGenerator) -> [UInt8] {
        var writer = ByteWriter()
        writer.write(Data(filler(&generator, count: 4)))
        writer.write(value)
        return record(tag: tag, payload: [UInt8](writer.data))
    }

    /// Builds a tagged block whose JPEG sits after the records and an optional gap.
    static func taggedBlock(jpeg: [UInt8], sizeValue: (Int) -> Int, _ generator: inout SeededGenerator) -> [UInt8] {
        let otherTags = [LiveViewFrameTag.streamInfo, LiveViewFrameTag.histogram, LiveViewFrameTag.posture, LiveViewFrameTag.level]
        let extra = (0..<Int.random(in: 0...3, using: &generator)).map { _ in
            record(tag: otherTags.randomElement(using: &generator)!, payload: filler(&generator, count: Int.random(in: 0...24, using: &generator)))
        }
        let recordsLength = extra.reduce(0) { $0 + $1.count } + 2 * (TaggedRecords.headerLength + 8)
        let gap = filler(&generator, count: Int.random(in: 0...16, using: &generator))
        let offset = recordsLength + gap.count
        var records = extra
        records.insert(valueRecord(tag: LiveViewFrameTag.jpegOffset, value: UInt32(offset), &generator), at: Int.random(in: 0...records.count, using: &generator))
        records.insert(valueRecord(tag: LiveViewFrameTag.jpegSize, value: UInt32(sizeValue(jpeg.count)), &generator), at: Int.random(in: 0...records.count, using: &generator))
        let head = records.flatMap { $0 } + gap
        precondition(head.count == offset)
        return head + jpeg + filler(&generator, count: Int.random(in: 0...16, using: &generator))
    }

    @Test("Offset and size records locate the image when the size value is length + 12")
    func taggedExtraction() throws {
        try forEachSeed { seed, generator in
            let image = Self.jpeg(&generator)
            let block = Self.taggedBlock(jpeg: image, sizeValue: { $0 + 12 }, &generator)
            let result = try LiveViewFrameParser.extractJPEG(from: Data(block))
            #expect(result.data == Data(image), "seed \(seed)")
            #expect(result.extraction == .tagged, "seed \(seed)")
        }
    }

    @Test("A size value without the 12-byte excess still yields the whole image by scanning for its end")
    func taggedStartWithShortSize() throws {
        try forEachSeed { seed, generator in
            let image = Self.jpeg(&generator)
            let block = Self.taggedBlock(jpeg: image, sizeValue: { $0 }, &generator)
            let result = try LiveViewFrameParser.extractJPEG(from: Data(block))
            #expect(result.data == Data(image), "seed \(seed)")
            #expect(result.extraction == .taggedStartScannedEnd, "seed \(seed)")
        }
    }

    @Test("A block that is a bare JPEG is found by scanning")
    func headerlessJPEG() throws {
        try forEachSeed { seed, generator in
            let image = Self.jpeg(&generator)
            let result = try LiveViewFrameParser.extractJPEG(from: Data(image))
            #expect(result.data == Data(image), "seed \(seed)")
            #expect(result.extraction == .scanned, "seed \(seed)")
        }
    }

    @Test("An offset record that points away from a start marker falls back to scanning")
    func misleadingOffset() throws {
        try forEachSeed { seed, generator in
            let image = Self.jpeg(&generator)
            var block = Self.taggedBlock(jpeg: image, sizeValue: { $0 + 12 }, &generator)
            let offsetRecordIndex = Self.recordStart(of: LiveViewFrameTag.jpegOffset, in: block)
            Self.store(UInt32(block.count + 5), at: offsetRecordIndex + 12, in: &block)
            let result = try LiveViewFrameParser.extractJPEG(from: Data(block))
            #expect(result.data == Data(image), "seed \(seed)")
            #expect(result.extraction == .scanned, "seed \(seed)")
        }
    }

    @Test("A block without a start and end marker is refused")
    func noImage() {
        forEachSeed { _, generator in
            let block = Self.filler(&generator, count: Int.random(in: 0...300, using: &generator))
            #expect(throws: ProtocolError.noJPEG) { try LiveViewFrameParser.extractJPEG(from: Data(block)) }
        }
        #expect(throws: ProtocolError.noJPEG) { try LiveViewFrameParser.extractJPEG(from: Data([0xFF, 0xD8, 0x00, 0x01])) }
    }

    @Test("Random blocks never read out of bounds")
    func randomBlocksAreSafe() {
        forEachSeed(3000) { _, generator in
            let block = generator.bytes(count: Int.random(in: 0...96, using: &generator))
            _ = try? LiveViewFrameParser.extractJPEG(from: Data(block))
        }
    }

    @Test("A slice of a larger buffer is read from its own first byte")
    func sliceIndices() throws {
        var generator = SeededGenerator(seed: 42)
        let image = Self.jpeg(&generator)
        let block = Self.taggedBlock(jpeg: image, sizeValue: { $0 + 12 }, &generator)
        let backing = Data([0x01, 0x02, 0x03] + block)
        let slice = backing[3...]
        #expect(try LiveViewFrameParser.extractJPEG(from: slice).data == Data(image))
    }

    static func recordStart(of tag: UInt32, in block: [UInt8]) -> Int {
        TaggedRecords.scan(Data(block)).records.first { $0.tag == tag }!.offset
    }

    static func store(_ value: UInt32, at index: Int, in block: inout [UInt8]) {
        for byte in 0..<4 {
            block[index + byte] = UInt8(truncatingIfNeeded: value >> (8 * UInt32(byte)))
        }
    }
}

@Suite("Tagged records")
struct TaggedRecordTests {
    @Test("Strict parsing refuses a record longer than the block; scanning stops there")
    func overrun() {
        var writer = ByteWriter()
        writer.write(UInt32(0x1700_0000))
        writer.write(UInt32(4))
        writer.write(Data([1, 2, 3, 4]))
        writer.write(UInt32(0x1700_0001))
        writer.write(UInt32(100))
        writer.write(Data([9, 9]))
        let block = writer.data
        #expect(throws: ProtocolError.recordOverrun(tag: 0x1700_0001, offset: 12, declaredLength: 100, available: 2)) {
            try TaggedRecords.parse(block)
        }
        let scan = TaggedRecords.scan(block)
        #expect(scan.records.map(\.tag) == [0x1700_0000])
        #expect(scan.records.first?.payload == Data([1, 2, 3, 4]))
        #expect(scan.stoppedAt == 12)
    }

    @Test("Records with empty payloads advance by their header")
    func emptyPayloads() throws {
        var writer = ByteWriter()
        for tag in [UInt32(1), 2, 3] {
            writer.write(tag)
            writer.write(UInt32(0))
        }
        let records = try TaggedRecords.parse(writer.data)
        #expect(records.map(\.tag) == [1, 2, 3])
        #expect(records.map(\.offset) == [0, 8, 16])
    }
}
