import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

/// Decodes live-view JPEG images into IOSurface-backed BGRA pixel buffers at their own size.
public final class JPEGDecoder: Sendable {
    private let pools = PixelBufferPools()

    public init() {}

    public func decode(_ jpeg: Data) throws(VideoError) -> CVPixelBuffer {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, options),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw .decodeFailed
        }
        let buffer = try pools.makeBuffer(size: PixelSize(width: image.width, height: image.height))
        try draw(image, into: buffer)
        return buffer
    }

    private func draw(_ image: CGImage, into buffer: CVPixelBuffer) throws(VideoError) {
        try buffer.withLockedBase(readOnly: false) { (base, bytesPerRow) throws(VideoError) in
            guard let context = CGContext(
                data: base,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else {
                throw .contextCreationFailed
            }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
    }
}
