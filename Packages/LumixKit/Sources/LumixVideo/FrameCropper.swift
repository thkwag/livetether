import Accelerate
import CoreVideo
import Foundation

/// Cuts a rectangle out of a picture and scales it to fill another picture. The rectangle may reach
/// past the picture's edges; the part outside the picture is black.
public enum FrameCropper {
    public static func crop(_ source: CVPixelBuffer, to rect: PixelRect, into target: CVPixelBuffer) throws(VideoError) {
        try source.requireBGRA()
        try target.requireBGRA()
        let size = source.pixelSize
        guard rect.width > 0, rect.height > 0 else { throw .cropOutOfBounds }
        // The part of the rectangle that shows the picture, and where it lands in the target.
        let left = max(rect.x, 0), top = max(rect.y, 0)
        let right = min(rect.x + rect.width, size.width), bottom = min(rect.y + rect.height, size.height)
        guard right > left, bottom > top else { throw .cropOutOfBounds }
        let targetWidth = CVPixelBufferGetWidth(target), targetHeight = CVPixelBufferGetHeight(target)
        let scaleX = Double(targetWidth) / Double(rect.width), scaleY = Double(targetHeight) / Double(rect.height)
        let outX = Int((Double(left - rect.x) * scaleX).rounded())
        let outY = Int((Double(top - rect.y) * scaleY).rounded())
        let outWidth = min(targetWidth - outX, Int((Double(right - left) * scaleX).rounded()))
        let outHeight = min(targetHeight - outY, Int((Double(bottom - top) * scaleY).rounded()))
        guard outWidth > 0, outHeight > 0 else { throw .cropOutOfBounds }
        let covers = outX == 0 && outY == 0 && outWidth == targetWidth && outHeight == targetHeight
        try source.withLockedBase(readOnly: true) { (sourceBase, sourceRowBytes) throws(VideoError) in
            try target.withLockedBase(readOnly: false) { (targetBase, targetRowBytes) throws(VideoError) in
                if !covers {
                    var whole = vImage_Buffer(data: targetBase, height: vImagePixelCount(targetHeight), width: vImagePixelCount(targetWidth), rowBytes: targetRowBytes)
                    let fill = FrameCompositor.black.withUnsafeBufferPointer { color in
                        vImageBufferFill_ARGB8888(&whole, color.baseAddress!, vImage_Flags(kvImageNoFlags))
                    }
                    guard fill == kvImageNoError else { throw .scaleFailed(fill) }
                }
                var input = vImage_Buffer(
                    data: sourceBase.advanced(by: top * sourceRowBytes + left * 4),
                    height: vImagePixelCount(bottom - top),
                    width: vImagePixelCount(right - left),
                    rowBytes: sourceRowBytes
                )
                var output = vImage_Buffer(
                    data: targetBase.advanced(by: outY * targetRowBytes + outX * 4),
                    height: vImagePixelCount(outHeight),
                    width: vImagePixelCount(outWidth),
                    rowBytes: targetRowBytes
                )
                let status = vImageScale_ARGB8888(&input, &output, nil, vImage_Flags(kvImageHighQualityResampling))
                guard status == kvImageNoError else { throw .scaleFailed(status) }
            }
        }
    }
}
