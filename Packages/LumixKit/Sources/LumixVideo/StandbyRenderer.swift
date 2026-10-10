import CoreGraphics
import CoreText
import CoreVideo
import Foundation
import os

/// The text shown on the virtual camera while no camera picture is available.
public struct StandbyMessage: Hashable, Sendable {
    public var title: String
    public var detail: String?

    public init(title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }
}

/// Draws the standby frame: a dark background with a centered title and an optional detail line.
///
/// The rendered frame is kept per message and size, so repeated requests return the same
/// immutable buffer instead of drawing again every frame.
public final class StandbyRenderer: Sendable {
    /// Background color in sRGB, 0...1.
    public static let background: (red: CGFloat, green: CGFloat, blue: CGFloat) = (0.11, 0.11, 0.12)

    private struct Key: Hashable {
        let message: StandbyMessage
        let size: PixelSize
    }

    private let cache = OSAllocatedUnfairLock<(key: Key, buffer: SendableBuffer)?>(initialState: nil)

    public init() {}

    public func frame(for message: StandbyMessage, size: PixelSize) throws(VideoError) -> CVPixelBuffer {
        let key = Key(message: message, size: size)
        if let cached = cache.withLock({ $0 }), cached.key == key {
            return cached.buffer.buffer
        }
        let buffer = try PixelBufferPool(size: size).makeBuffer()
        try draw(message, into: buffer)
        let entry = (key: key, buffer: SendableBuffer(buffer: buffer))
        cache.withLock { $0 = entry }
        return buffer
    }

    private func draw(_ message: StandbyMessage, into buffer: CVPixelBuffer) throws(VideoError) {
        let size = buffer.pixelSize
        try buffer.withLockedBase(readOnly: false) { (base, bytesPerRow) throws(VideoError) in
            guard let context = CGContext(
                data: base,
                width: size.width,
                height: size.height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else {
                throw .contextCreationFailed
            }
            let background = Self.background
            context.setFillColor(red: background.red, green: background.green, blue: background.blue, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))

            let titleSize = CGFloat(size.height) * 0.06
            let detailSize = CGFloat(size.height) * 0.035
            let title = line(message.title, fontSize: titleSize, weight: 0.4, gray: 0.95)
            let detail = message.detail.map { line($0, fontSize: detailSize, weight: 0, gray: 0.7) }
            let gap = detail == nil ? 0 : CGFloat(size.height) * 0.03
            let detailHeight = detail.map { height(of: $0) } ?? 0
            let blockHeight = height(of: title) + gap + detailHeight
            // Core Graphics puts the origin at the bottom-left; the block is centered vertically.
            var baseline = (CGFloat(size.height) + blockHeight) / 2 - ascent(of: title)
            drawCentered(title, baseline: baseline, width: size.width, in: context)
            if let detail {
                baseline -= descent(of: title) + gap + ascent(of: detail)
                drawCentered(detail, baseline: baseline, width: size.width, in: context)
            }
        }
    }

    private func line(_ text: String, fontSize: CGFloat, weight: CGFloat, gray: CGFloat) -> CTLine {
        let traits = [kCTFontWeightTrait: weight] as CFDictionary
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontTraitsAttribute: traits] as CFDictionary)
        let base = CTFontCreateUIFontForLanguage(.system, fontSize, nil) ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let font = CTFontCreateCopyWithAttributes(base, fontSize, nil, descriptor)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: gray, alpha: 1),
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    private func ascent(of line: CTLine) -> CGFloat {
        var ascent: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, nil, nil)
        return ascent
    }

    private func descent(of line: CTLine) -> CGFloat {
        var descent: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, nil, &descent, nil)
        return descent
    }

    private func height(of line: CTLine) -> CGFloat {
        ascent(of: line) + descent(of: line)
    }

    private func drawCentered(_ line: CTLine, baseline: CGFloat, width: Int, in context: CGContext) {
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        context.textPosition = CGPoint(x: (CGFloat(width) - lineWidth) / 2, y: baseline)
        CTLineDraw(line, context)
    }
}

/// A pixel buffer that is never written after it is cached.
struct SendableBuffer: @unchecked Sendable {
    let buffer: CVPixelBuffer
}
