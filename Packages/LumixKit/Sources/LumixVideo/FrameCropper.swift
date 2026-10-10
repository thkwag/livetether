import Accelerate
import CoreVideo
import Foundation

/// Cuts a rectangle out of a picture and scales it to fill another picture.
public enum FrameCropper {
    public static func crop(_ source: CVPixelBuffer, to rect: PixelRect, into target: CVPixelBuffer) throws(VideoError) {
        try source.requireBGRA()
        try target.requireBGRA()
        let size = source.pixelSize
        guard rect.x >= 0, rect.y >= 0, rect.width > 0, rect.height > 0,
              rect.x + rect.width <= size.width, rect.y + rect.height <= size.height else {
            throw .cropOutOfBounds
        }
        try source.withLockedBase(readOnly: true) { (sourceBase, sourceRowBytes) throws(VideoError) in
            try target.withLockedBase(readOnly: false) { (targetBase, targetRowBytes) throws(VideoError) in
                var input = vImage_Buffer(
                    data: sourceBase.advanced(by: rect.y * sourceRowBytes + rect.x * 4),
                    height: vImagePixelCount(rect.height),
                    width: vImagePixelCount(rect.width),
                    rowBytes: sourceRowBytes
                )
                var output = vImage_Buffer(
                    data: targetBase,
                    height: vImagePixelCount(CVPixelBufferGetHeight(target)),
                    width: vImagePixelCount(CVPixelBufferGetWidth(target)),
                    rowBytes: targetRowBytes
                )
                let status = vImageScale_ARGB8888(&input, &output, nil, vImage_Flags(kvImageHighQualityResampling))
                guard status == kvImageNoError else { throw .scaleFailed(status) }
            }
        }
    }
}
