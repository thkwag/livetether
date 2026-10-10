import Foundation
import LumixTestSupport
import Testing
@testable import LumixProtocol

@Suite("Live-view sizes")
struct LiveViewSizeTests {
    /// The `0x9414`/`0x0D800012` reply of a DC-GC9 recorded in libgphoto2 `ptp_panasonic_9414_0d800012`.
    static let gc9SizeList = Data(hex: """
        12 00 80 0d  1c 00 00 00
        03 00  08 00
        e0 01 80 02 20 00 1e 00
        d0 02 c0 03 5e 01 1e 00
        c0 03 00 05 bc 02 1e 00
        """)

    /// The `0x9414`/`0x0D800011` reply recorded in libgphoto2 `ptp_panasonic_9414_0d800011`.
    static let gc9CurrentSize = Data(hex: "11 00 80 0d 08 00 00 00 e0 01 80 02 00 00 1e 00")

    @Test("The recorded GC9 list decodes to three 30 fps sizes")
    func decodeRecordedList() throws {
        let sizes = try LiveViewSize.decodeList(from: Self.gc9SizeList)
        #expect(sizes == [
            LiveViewSize(width: 640, height: 480, opaqueValue: 0x20, framesPerSecond: 30),
            LiveViewSize(width: 960, height: 720, opaqueValue: 0x15E, framesPerSecond: 30),
            LiveViewSize(width: 1280, height: 960, opaqueValue: 0x2BC, framesPerSecond: 30),
        ])
    }

    @Test("The automatic choice picks 1280×960 from the recorded list")
    func selectFromRecordedList() throws {
        let sizes = try LiveViewSize.decodeList(from: Self.gc9SizeList)
        #expect(LiveViewSize.preferred(in: sizes) == LiveViewSize(width: 1280, height: 960, opaqueValue: 0x2BC, framesPerSecond: 30))
    }

    @Test("The recorded current size decodes to 640×480")
    func decodeRecordedCurrent() throws {
        let size = try LiveViewSize.decodeCurrent(from: Self.gc9CurrentSize)
        #expect(size == LiveViewSize(width: 640, height: 480, opaqueValue: 0, framesPerSecond: 30))
    }

    @Test("The set-property block is the current-size record of the same entry")
    func setBlockMatchesCurrentRecord() throws {
        let size = LiveViewSize(width: 640, height: 480, opaqueValue: 0, framesPerSecond: 30)
        #expect(size.setPropertyBlock() == Self.gc9CurrentSize)
        #expect(try LiveViewSize.decodeCurrent(from: size.setPropertyBlock()) == size)
    }

    @Test("Selection keeps only the requested rate and the widest, then tallest, first-seen entry")
    func selectionProperty() {
        forEachSeed { seed, generator in
            let sizes = (0..<Int.random(in: 0...8, using: &generator)).map { _ in
                LiveViewSize(
                    width: [640, 960, 1280, 1920].randomElement(using: &generator)!,
                    height: [480, 720, 960, 1080].randomElement(using: &generator)!,
                    opaqueValue: .random(in: .min ... .max, using: &generator),
                    framesPerSecond: [24, 30, 60].randomElement(using: &generator)!
                )
            }
            let chosen = LiveViewSize.preferred(in: sizes)
            let candidates = sizes.filter { $0.framesPerSecond == 30 }
            guard let chosen else {
                #expect(candidates.isEmpty, "seed \(seed)")
                return
            }
            #expect(chosen.framesPerSecond == 30, "seed \(seed)")
            let largest = candidates.map { ($0.width, $0.height) }.max { $0 < $1 }!
            #expect((chosen.width, chosen.height) == largest, "seed \(seed)")
            let firstIndex = sizes.firstIndex { $0.framesPerSecond == 30 && ($0.width, $0.height) == largest }!
            #expect(sizes[firstIndex] == chosen, "seed \(seed)")
        }
    }

    @Test("Every truncation of the recorded list is refused")
    func truncatedListIsRefused() {
        for length in 0..<Self.gc9SizeList.count {
            #expect(throws: ProtocolError.self, "length \(length)") {
                try LiveViewSize.decodeList(from: Self.gc9SizeList.prefix(length))
            }
        }
    }

    @Test("An entry length other than eight is refused")
    func entryLengthIsChecked() {
        var block = Self.gc9SizeList
        block[10] = 0x0A
        #expect(throws: ProtocolError.unexpectedEntryLength(10)) { try LiveViewSize.decodeList(from: block) }
    }

    @Test("A count larger than the record holds is refused")
    func countIsChecked() {
        var block = Self.gc9SizeList
        block[8] = 0x04
        #expect(throws: ProtocolError.entriesExceedRecord(count: 4, recordLength: 28)) { try LiveViewSize.decodeList(from: block) }
    }

    @Test("A block without the list record is refused")
    func missingRecordIsRefused() {
        #expect(throws: ProtocolError.missingRecord(tag: PanasonicValue.liveViewSizeList)) {
            try LiveViewSize.decodeList(from: Self.gc9CurrentSize)
        }
    }

    @Test("Random blocks never read out of bounds")
    func randomBlocksAreSafe() {
        forEachSeed(2000) { _, generator in
            let block = Data(generator.bytes(count: Int.random(in: 0...64, using: &generator)))
            _ = try? LiveViewSize.decodeList(from: block)
            _ = try? LiveViewSize.decodeCurrent(from: block)
        }
    }
}
