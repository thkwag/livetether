import Accelerate
import CoreVideo
import Foundation

/// Places a camera picture in an output frame: opaque black everywhere, the picture scaled to fit and centered.
public enum FrameCompositor {
    /// Opaque black in BGRA memory order.
    static let black: [UInt8] = [0, 0, 0, 0xFF]

    public static func compose(_ source: CVPixelBuffer, into target: CVPixelBuffer) throws(VideoError) {
        try source.requireBGRA()
        try target.requireBGRA()
        let placement = AspectFit.rect(fitting: source.pixelSize, into: target.pixelSize)
        try source.withLockedBase(readOnly: true) { (sourceBase, sourceRowBytes) throws(VideoError) in
            try target.withLockedBase(readOnly: false) { (targetBase, targetRowBytes) throws(VideoError) in
                var whole = vImage_Buffer(
                    data: targetBase,
                    height: vImagePixelCount(CVPixelBufferGetHeight(target)),
                    width: vImagePixelCount(CVPixelBufferGetWidth(target)),
                    rowBytes: targetRowBytes
                )
                let fillStatus = black.withUnsafeBufferPointer { color in
                    vImageBufferFill_ARGB8888(&whole, color.baseAddress!, vImage_Flags(kvImageNoFlags))
                }
                guard fillStatus == kvImageNoError else { throw .scaleFailed(fillStatus) }
                guard placement.width > 0, placement.height > 0 else { return }

                var input = vImage_Buffer(
                    data: sourceBase,
                    height: vImagePixelCount(CVPixelBufferGetHeight(source)),
                    width: vImagePixelCount(CVPixelBufferGetWidth(source)),
                    rowBytes: sourceRowBytes
                )
                var output = vImage_Buffer(
                    data: targetBase.advanced(by: placement.y * targetRowBytes + placement.x * 4),
                    height: vImagePixelCount(placement.height),
                    width: vImagePixelCount(placement.width),
                    rowBytes: targetRowBytes
                )
                let status: vImage_Error
                if input.width == output.width, input.height == output.height {
                    status = vImageCopyBuffer(&input, &output, 4, vImage_Flags(kvImageNoFlags))
                } else {
                    status = vImageScale_ARGB8888(&input, &output, nil, vImage_Flags(kvImageNoFlags))
                }
                guard status == kvImageNoError else { throw .scaleFailed(status) }
            }
        }
    }
}
