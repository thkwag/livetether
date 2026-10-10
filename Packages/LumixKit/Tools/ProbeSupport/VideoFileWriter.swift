import AVFoundation
import CoreVideo
import Foundation

/// Writes pictures to an H.264 movie file, for a person to watch what a probe did.
public final class VideoFileWriter {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor

    public init(url: URL, size: CGSize) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
    }

    public func append(_ picture: CVPixelBuffer, at seconds: Double) {
        while !input.isReadyForMoreMediaData {
            Thread.sleep(forTimeInterval: 0.002)
        }
        adaptor.append(picture, withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    public func finish() async {
        input.markAsFinished()
        await writer.finishWriting()
    }
}
