import AVFoundation
import CoreVideo
import Foundation
import LumixProbeSupport
import LumixVideo
import LumixVirtualCamera

/// Test tool: runs the automatic framing over a video file, standing in for the app and a camera.
///
/// Every frame goes through the same detector, framer and cropper the app uses. The tool prints
/// how often people were found and how the crop moved, and counts frames in which a framed person
/// fell outside the crop. Without --no-sink it also feeds the framed pictures to the camera
/// extension in real time, so the result can be watched in any camera app (quit LiveTether first).
///
/// With --write <file>, the framed pictures are also written to a movie file.
///
/// Usage: `lumix-framing-probe <video> [--size 1920x1080] [--shot headAndShoulders|upperBody] [--no-sink] [--write <file>]`
@main
struct FramingProbe {
    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        let feedsSink = !arguments.contains("--no-sink")
        arguments.removeAll { $0 == "--no-sink" }
        var output = PixelSize(width: 1920, height: 1080)
        if let index = arguments.firstIndex(of: "--size"), index + 1 < arguments.count {
            let parts = arguments[index + 1].split(separator: "x").compactMap { Int($0) }
            if parts.count == 2 { output = PixelSize(width: parts[0], height: parts[1]) }
            arguments.removeSubrange(index...(index + 1))
        }
        var parameters = FramingParameters()
        if let index = arguments.firstIndex(of: "--shot"), index + 1 < arguments.count {
            parameters.shot = FramingShot(rawValue: arguments[index + 1]) ?? .headAndShoulders
            arguments.removeSubrange(index...(index + 1))
        }
        var writeURL: URL?
        if let index = arguments.firstIndex(of: "--write"), index + 1 < arguments.count {
            writeURL = URL(fileURLWithPath: arguments[index + 1])
            arguments.removeSubrange(index...(index + 1))
        }
        guard let path = arguments.first else {
            print("usage: lumix-framing-probe <video> [--size 1920x1080] [--no-sink]")
            exit(2)
        }
        do {
            try await run(URL(fileURLWithPath: path), output: output, feedsSink: feedsSink, writeURL: writeURL, parameters: parameters)
        } catch {
            print("Framing probe failed: \(error)")
            exit(1)
        }
    }

    static func run(_ url: URL, output: PixelSize, feedsSink: Bool, writeURL: URL?, parameters: FramingParameters) async throws {
        let movie = try writeURL.map { try VideoFileWriter(url: $0, size: CGSize(width: output.width, height: output.height)) }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            print("The file has no video track")
            exit(1)
        }
        let reader = try AVAssetReader(asset: asset)
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        reader.add(trackOutput)
        reader.startReading()

        let sink = SinkStreamClient()
        if feedsSink {
            try sink.connect()
        }
        let detector = PersonDetector()
        let pools = PixelBufferPools()
        var framer: AutoFramer?
        var lastDetection = -Double.infinity
        var detections = 0
        var detectionsWithPeople = 0
        var detectionTime = 0.0
        var frames = 0
        var outside = 0
        var lastSubjects: [FramingSubject] = []
        var lastCrop: PixelRect?
        var travel = 0.0
        let clock = ContinuousClock()
        let started = clock.now

        while let sample = trackOutput.copyNextSampleBuffer(), let picture = CMSampleBufferGetImageBuffer(sample) {
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let source = picture.pixelSize
            if framer?.source != source {
                framer = AutoFramer(source: source, output: output, parameters: parameters)
            }
            if time - lastDetection >= 0.2 {
                let before = clock.now
                lastSubjects = try detector.detect(in: picture)
                let spent = clock.now - before
                detectionTime += Double(spent.components.attoseconds) / 1e18 + Double(spent.components.seconds)
                detections += 1
                if !lastSubjects.isEmpty { detectionsWithPeople += 1 }
                framer?.observe(lastSubjects, at: time)
                lastDetection = time
            }
            guard var current = framer else { continue }
            let crop = current.crop(at: time)
            framer = current
            frames += 1
            if let previous = lastCrop {
                travel += abs(Double(crop.x - previous.x)) + abs(Double(crop.y - previous.y))
            }
            lastCrop = crop
            // After the framing has had time to follow, every person's head should be inside the crop.
            if time > 3, lastSubjects.count == 1, let face = lastSubjects[0].face {
                let x = face.midX * Double(source.width)
                let y = face.midY * Double(source.height)
                if x < Double(crop.x) || x > Double(crop.x + crop.width) || y < Double(crop.y) || y > Double(crop.y + crop.height) {
                    outside += 1
                }
            }
            if let movie {
                let framed = try pools.makeBuffer(size: output)
                try FrameCropper.crop(picture, to: crop, into: framed)
                movie.append(framed, at: time)
            }
            if feedsSink {
                let target = try pools.makeBuffer(size: output)
                try FrameCropper.crop(picture, to: crop, into: target)
                try? sink.send(target)
                try await clock.sleep(until: started + .milliseconds(Int(time * 1000)))
            }
        }
        sink.disconnect()
        await movie?.finish()
        print("frames \(frames), detections \(detections) (\(detectionsWithPeople) found people)")
        if detections > 0 {
            print(String(format: "detection takes %.1f ms on average", detectionTime / Double(detections) * 1000))
        }
        print(String(format: "crop travelled %.0f px; a single face was outside the crop in %d frames", travel, outside))
    }
}
