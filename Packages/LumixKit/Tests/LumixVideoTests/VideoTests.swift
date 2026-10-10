import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import LumixTestSupport
import Testing
import UniformTypeIdentifiers
@testable import LumixVideo

@Suite("Aspect fit")
struct AspectFitTests {
    @Test("A 4:3 picture in a 16:9 frame is pillarboxed")
    func pillarbox() {
        #expect(AspectFit.rect(fitting: PixelSize(width: 1280, height: 960), into: PixelSize(width: 1920, height: 1080))
            == PixelRect(x: 240, y: 0, width: 1440, height: 1080))
        #expect(AspectFit.rect(fitting: PixelSize(width: 1920, height: 1080), into: PixelSize(width: 1280, height: 960))
            == PixelRect(x: 0, y: 120, width: 1280, height: 720))
    }

    @Test("The placement fits, fills one side, keeps the ratio within a pixel, and is centered")
    func placementProperties() {
        forEachSeed(2000) { seed, generator in
            let source = PixelSize(width: .random(in: 1...4000, using: &generator), height: .random(in: 1...4000, using: &generator))
            let target = PixelSize(width: .random(in: 1...4000, using: &generator), height: .random(in: 1...4000, using: &generator))
            let rect = AspectFit.rect(fitting: source, into: target)
            let context = "seed \(seed): \(source) into \(target) gave \(rect)"
            #expect(rect.x >= 0 && rect.y >= 0 && rect.x + rect.width <= target.width && rect.y + rect.height <= target.height, "\(context)")
            #expect(rect.width == target.width || rect.height == target.height, "\(context)")
            let exactHeight = Double(rect.width) * Double(source.height) / Double(source.width)
            let exactWidth = Double(rect.height) * Double(source.width) / Double(source.height)
            #expect(abs(exactHeight - Double(rect.height)) <= 1 || abs(exactWidth - Double(rect.width)) <= 1, "\(context)")
            let horizontalMargins = (rect.x, target.width - rect.x - rect.width)
            let verticalMargins = (rect.y, target.height - rect.y - rect.height)
            #expect(abs(horizontalMargins.0 - horizontalMargins.1) <= 1 && abs(verticalMargins.0 - verticalMargins.1) <= 1, "\(context)")
        }
    }
}

@Suite("Frame composition")
struct FrameCompositorTests {
    @Test("The picture fills its placement and the margins are opaque black")
    func composeMargins() throws {
        let source = try PixelBufferPool(size: PixelSize(width: 640, height: 480)).makeBuffer()
        try fill(source, bgra: [0, 0, 0xFF, 0xFF])
        let target = try PixelBufferPool(size: PixelSize(width: 1280, height: 720)).makeBuffer()
        try fill(target, bgra: [0x12, 0x34, 0x56, 0x78])
        try FrameCompositor.compose(source, into: target)
        let placement = AspectFit.rect(fitting: source.pixelSize, into: target.pixelSize)
        #expect(placement == PixelRect(x: 160, y: 0, width: 960, height: 720))
        #expect(try pixel(target, x: 0, y: 0) == [0, 0, 0, 0xFF])
        #expect(try pixel(target, x: 159, y: 360) == [0, 0, 0, 0xFF])
        #expect(try pixel(target, x: 1120, y: 360) == [0, 0, 0, 0xFF])
        #expect(try pixel(target, x: 160, y: 360) == [0, 0, 0xFF, 0xFF])
        #expect(try pixel(target, x: 640, y: 0) == [0, 0, 0xFF, 0xFF])
        #expect(try pixel(target, x: 1119, y: 719) == [0, 0, 0xFF, 0xFF])
    }

    @Test("A picture of the frame's own size is copied unchanged")
    func composeSameSize() throws {
        let size = PixelSize(width: 64, height: 48)
        let source = try PixelBufferPool(size: size).makeBuffer()
        try source.withLockedBase(readOnly: false) { (base, rowBytes) throws(VideoError) in
            for y in 0..<size.height {
                for x in 0..<size.width {
                    let pixel = base.advanced(by: y * rowBytes + x * 4).assumingMemoryBound(to: UInt8.self)
                    pixel[0] = UInt8(x); pixel[1] = UInt8(y); pixel[2] = 0x80; pixel[3] = 0xFF
                }
            }
        }
        let target = try PixelBufferPool(size: size).makeBuffer()
        try FrameCompositor.compose(source, into: target)
        #expect(try pixel(target, x: 13, y: 29) == [13, 29, 0x80, 0xFF])
        #expect(try pixel(target, x: 63, y: 47) == [63, 47, 0x80, 0xFF])
    }

    @Test("Pool buffers are IOSurface-backed so they can cross processes")
    func ioSurfaceBacking() throws {
        let buffer = try PixelBufferPool(size: PixelSize(width: 32, height: 32)).makeBuffer()
        #expect(CVPixelBufferGetIOSurface(buffer) != nil)
    }
}

@Suite("JPEG decoding")
struct JPEGDecoderTests {
    @Test("A JPEG decodes at its own size with its colors")
    func decodesSizeAndColor() throws {
        let jpeg = try makeJPEG(width: 320, height: 240, red: 0.1, green: 0.8, blue: 0.3)
        let buffer = try JPEGDecoder().decode(jpeg)
        #expect(buffer.pixelSize == PixelSize(width: 320, height: 240))
        #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA)
        let center = try pixel(buffer, x: 160, y: 120)
        #expect(abs(Int(center[0]) - 77) <= 8, "blue \(center[0])")
        #expect(abs(Int(center[1]) - 204) <= 8, "green \(center[1])")
        #expect(abs(Int(center[2]) - 26) <= 8, "red \(center[2])")
        #expect(center[3] == 0xFF)
    }

    @Test("Bytes that are not an image are refused")
    func refusesGarbage() {
        #expect(throws: VideoError.decodeFailed) { try JPEGDecoder().decode(Data([0xFF, 0xD8, 0x00, 0xFF, 0xD9])) }
    }
}

@Suite("Standby frame")
struct StandbyRendererTests {
    static let size = PixelSize(width: 1280, height: 720)
    static let whole = PixelRect(x: 0, y: 0, width: 1280, height: 720)

    /// Title text is drawn at 95 % gray, detail text at 70 % gray; these bands select each.
    static func isTitleInk(_ pixel: [UInt8]) -> Bool { pixel[1] >= 0xE8 }
    static func isDetailInk(_ pixel: [UInt8]) -> Bool { (0xA8...0xBC).contains(pixel[1]) }

    @Test("The background is the standby color")
    func background() throws {
        let frame = try StandbyRenderer().frame(for: StandbyMessage(title: "카메라를 연결해 주세요"), size: Self.size)
        let background = StandbyRenderer.background
        let expected = [UInt8(background.blue * 255 + 0.5), UInt8(background.green * 255 + 0.5), UInt8(background.red * 255 + 0.5), 0xFF]
        let corner = try pixel(frame, x: 2, y: 2)
        #expect(zip(corner, expected).allSatisfy { abs(Int($0) - Int($1)) <= 2 }, "corner \(corner) background \(expected)")
    }

    @Test("The title is drawn, and the detail line is drawn below it only when there is one")
    func titleAndDetail() throws {
        let withDetail = try StandbyRenderer().frame(for: StandbyMessage(title: "카메라를 연결해 주세요", detail: "USB 모드: PC(Tether)"), size: Self.size)
        let titleOnly = try StandbyRenderer().frame(for: StandbyMessage(title: "카메라를 연결해 주세요"), size: Self.size)
        for frame in [withDetail, titleOnly] {
            #expect(try countPixels(frame, in: Self.whole, where: Self.isTitleInk) > 1000, "the title is missing")
        }
        #expect(try detailInkBelowTitle(withDetail) > 30, "the detail line is missing")
        #expect(try detailInkBelowTitle(titleOnly) == 0, "detail ink appeared without a detail line")
    }

    @Test("The same message and size reuse the rendered frame; another message renders anew")
    func reuse() throws {
        let renderer = StandbyRenderer()
        let message = StandbyMessage(title: "카메라를 연결해 주세요")
        let frame = try renderer.frame(for: message, size: Self.size)
        #expect(try renderer.frame(for: message, size: Self.size) === frame)
        #expect(try renderer.frame(for: StandbyMessage(title: "다른 문구"), size: Self.size) !== frame)
    }

    /// Detail-gray pixels in the rows below the lowest title-ink row, skipping the title's anti-aliased edge.
    func detailInkBelowTitle(_ frame: CVPixelBuffer) throws -> Int {
        var lowestTitleRow = 0
        for y in 0..<Self.size.height where try countPixels(frame, in: PixelRect(x: 0, y: y, width: Self.size.width, height: 1), where: Self.isTitleInk) > 0 {
            lowestTitleRow = y
        }
        let start = lowestTitleRow + 4
        return try countPixels(frame, in: PixelRect(x: 0, y: start, width: Self.size.width, height: Self.size.height - start), where: Self.isDetailInk)
    }
}

// MARK: - Helpers

func fill(_ buffer: CVPixelBuffer, bgra: [UInt8]) throws {
    try buffer.withLockedBase(readOnly: false) { (base, rowBytes) throws(VideoError) in
        for y in 0..<CVPixelBufferGetHeight(buffer) {
            for x in 0..<CVPixelBufferGetWidth(buffer) {
                base.advanced(by: y * rowBytes + x * 4).copyMemory(from: bgra, byteCount: 4)
            }
        }
    }
}

func pixel(_ buffer: CVPixelBuffer, x: Int, y: Int) throws -> [UInt8] {
    try buffer.withLockedBase(readOnly: true) { (base, rowBytes) throws(VideoError) in
        let start = base.advanced(by: y * rowBytes + x * 4).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: start, count: 4))
    }
}

func countPixels(_ buffer: CVPixelBuffer, in rect: PixelRect, where predicate: ([UInt8]) -> Bool) throws -> Int {
    var count = 0
    for y in rect.y..<(rect.y + rect.height) {
        for x in stride(from: rect.x, to: rect.x + rect.width, by: 2) where predicate(try pixel(buffer, x: x, y: y)) {
            count += 1
        }
    }
    return count
}

func makeJPEG(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) throws -> Data {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = context.makeImage()!
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return output as Data
}
