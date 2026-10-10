import CoreGraphics
import CoreVideo
import Foundation
import LumixVideo
import LumixVirtualCamera

/// Test tool: feeds a moving test pattern into the camera extension's sink stream, standing in for
/// the app and a camera, so the extension can be checked in any camera app without hardware.
///
/// Usage: `lumix-sink-probe [seconds] [width] [height]` (defaults: 30 s, 1280 × 960). Quit the
/// LUMIX Webcam app first; only one client can own the sink stream.
@main
struct SinkProbe {
    static func main() async {
        let arguments = CommandLine.arguments.dropFirst().compactMap { Int($0) }
        let seconds = arguments.first ?? 30
        let size = PixelSize(width: arguments.dropFirst().first ?? 1280, height: arguments.dropFirst(2).first ?? 960)
        let sink = SinkStreamClient()
        do {
            try sink.connect()
        } catch {
            print("Cannot reach the camera extension's sink stream: \(error)")
            print("Is the extension installed and activated? Is the LUMIX Webcam app quit?")
            exit(1)
        }
        print("Sending a \(size) test pattern for \(seconds) s")
        let pool: PixelBufferPool
        do {
            pool = try PixelBufferPool(size: size)
        } catch {
            print("Cannot create pixel buffers: \(error)")
            exit(1)
        }
        let clock = ContinuousClock()
        let start = clock.now
        let interval = Duration.nanoseconds(1_000_000_000 / VirtualCameraFormats.framesPerSecond)
        var sent = 0
        var dropped = 0
        var frame = 0
        while clock.now - start < .seconds(seconds) {
            let due = start + interval * frame
            do {
                let buffer = try pool.makeBuffer()
                try TestPattern.draw(frame: frame, into: buffer)
                try sink.send(buffer)
                sent += 1
            } catch SinkError.queueFull {
                dropped += 1
            } catch {
                print("Frame \(frame) failed: \(error)")
            }
            frame += 1
            try? await clock.sleep(until: due + interval)
        }
        sink.disconnect()
        print("Sent \(sent) frames, \(dropped) dropped because the sink queue was full")
    }
}

/// Color bars with a white border and a white bar that sweeps across once a second.
enum TestPattern {
    static let bars: [(CGFloat, CGFloat, CGFloat)] = [
        (0.75, 0.75, 0.75), (0.75, 0.75, 0), (0, 0.75, 0.75), (0, 0.75, 0),
        (0.75, 0, 0.75), (0.75, 0, 0), (0, 0, 0.75),
    ]

    static func draw(frame: Int, into buffer: CVPixelBuffer) throws {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw VideoError.contextCreationFailed
        }
        let barWidth = CGFloat(width) / CGFloat(bars.count)
        for (index, color) in bars.enumerated() {
            context.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: 1)
            context.fill(CGRect(x: CGFloat(index) * barWidth, y: 0, width: barWidth + 1, height: CGFloat(height)))
        }
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        let sweep = CGFloat(frame % VirtualCameraFormats.framesPerSecond) / CGFloat(VirtualCameraFormats.framesPerSecond)
        context.fill(CGRect(x: sweep * CGFloat(width - 16), y: 0, width: 16, height: CGFloat(height)))
        context.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.setLineWidth(4)
        context.stroke(CGRect(x: 2, y: 2, width: width - 4, height: height - 4))
    }
}
