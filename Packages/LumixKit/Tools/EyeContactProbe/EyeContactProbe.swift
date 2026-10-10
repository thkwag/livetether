import AVFoundation
import CoreML
import CoreVideo
import Foundation
import LumixVideo

/// Test tool: runs the eye contact correction with a gaze model built by scripts/gaze-model/convert.py.
///
/// With a video file, it corrects the faces in every frame and reports how many faces it found and
/// how long finding landmarks and correcting took. Without one, it corrects a fixed pair of eyes in
/// a synthetic picture and checks that only the eye patches changed, which proves the model's
/// inputs and outputs are wired as the app expects.
///
/// Usage: `lumix-eye-contact-probe <GazeWarp.mlpackage> [video]`
@main
struct EyeContactProbe {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let modelPath = arguments.first else {
            print("usage: lumix-eye-contact-probe <GazeWarp.mlpackage> [video]")
            exit(2)
        }
        do {
            let compiled = try await MLModel.compileModel(at: URL(fileURLWithPath: modelPath))
            let corrector = EyeContactCorrector(model: try MLModel(contentsOf: compiled))
            if arguments.count > 1 {
                try await correctVideo(URL(fileURLWithPath: arguments[1]), corrector: corrector)
            } else {
                try selfCheck(corrector)
            }
        } catch {
            print("Eye contact probe failed: \(error)")
            exit(1)
        }
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    static func selfCheck(_ corrector: EyeContactCorrector) throws {
        let size = PixelSize(width: 1280, height: 960)
        let picture = try PixelBufferPool(size: size).makeBuffer()
        CVPixelBufferLockBaseAddress(picture, [])
        let base = CVPixelBufferGetBaseAddress(picture)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(picture)
        for y in 0..<size.height {
            for x in 0..<size.width {
                let offset = y * rowBytes + x * 4
                base[offset] = UInt8((x * 7 + y * 3) & 0xFF)
                base[offset + 1] = UInt8((x * 3 + y * 5) & 0xFF)
                base[offset + 2] = UInt8((x + y * 11) & 0xFF)
                base[offset + 3] = 255
            }
        }
        let before = Array(UnsafeBufferPointer(start: base, count: rowBytes * size.height))
        CVPixelBufferUnlockBaseAddress(picture, [])

        func eye(_ cx: Double) -> EyeOutline {
            EyeOutline(contour: [
                PixelPoint(x: cx - 30, y: 400), PixelPoint(x: cx - 15, y: 391), PixelPoint(x: cx, y: 388), PixelPoint(x: cx + 15, y: 391),
                PixelPoint(x: cx + 30, y: 399), PixelPoint(x: cx + 15, y: 407), PixelPoint(x: cx, y: 409), PixelPoint(x: cx - 15, y: 407),
            ])!
        }
        let face = FaceForGaze(leftEye: eye(560), rightEye: eye(720), yaw: 0, pitch: 0)
        let clock = ContinuousClock()
        var times: [Double] = []
        for _ in 0..<30 {
            let copy = try PixelBufferPool(size: size).makeBuffer()
            CVPixelBufferLockBaseAddress(copy, [])
            memcpy(CVPixelBufferGetBaseAddress(copy)!, before, before.count)
            CVPixelBufferUnlockBaseAddress(copy, [])
            let start = clock.now
            try corrector.correct(copy, face: face, strength: 1)
            times.append(milliseconds(clock.now - start))
        }
        try corrector.correct(picture, face: face, strength: 1)
        CVPixelBufferLockBaseAddress(picture, .readOnly)
        var changed = 0
        var changedOutside = 0
        for y in 0..<size.height {
            for x in 0..<size.width {
                let offset = y * rowBytes + x * 4
                guard (0..<3).contains(where: { base[offset + $0] != before[offset + $0] }) else { continue }
                changed += 1
                let inLeft = x >= 515 && x < 605 && y >= 359 && y < 427
                let inRight = x >= 675 && x < 765 && y >= 359 && y < 427
                if !inLeft && !inRight { changedOutside += 1 }
            }
        }
        CVPixelBufferUnlockBaseAddress(picture, .readOnly)
        times.sort()
        print(String(format: "correction of two eyes: median %.2f ms, slowest %.2f ms over %d runs", times[times.count / 2], times.last!, times.count))
        print("pixels changed: \(changed) inside the eye patches, \(changedOutside) outside")
        exit(changed > 0 && changedOutside == 0 ? 0 : 1)
    }

    static func correctVideo(_ url: URL, corrector: EyeContactCorrector) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            print("The file has no video track")
            exit(1)
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        reader.add(output)
        reader.startReading()
        let finder = FaceLandmarkFinder()
        let clock = ContinuousClock()
        var frames = 0
        var faces = 0
        var corrected = 0
        var findTime = 0.0
        var correctTime = 0.0
        while let sample = output.copyNextSampleBuffer(), let picture = CMSampleBufferGetImageBuffer(sample) {
            frames += 1
            let start = clock.now
            let found = try finder.faces(in: picture)
            let found_at = clock.now
            findTime += milliseconds(found_at - start)
            faces += found.count
            for face in found {
                let strength = EyeContactCorrector.strength(for: face)
                if strength > 0 { corrected += 1 }
                try corrector.correct(picture, face: face, strength: strength)
            }
            correctTime += milliseconds(clock.now - found_at)
        }
        print("frames \(frames), faces \(faces), faces corrected \(corrected)")
        if frames > 0 {
            print(String(format: "per frame: finding landmarks %.1f ms, correcting %.1f ms", findTime / Double(frames), correctTime / Double(frames)))
        }
    }
}
