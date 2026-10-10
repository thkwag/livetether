import AVFoundation
import CoreImage
import ImageIO
import CoreVideo
import Foundation
import LumixProbeSupport
import LumixVideo

/// Test tool: runs the eye contact correction with the published weights in a folder laid out as
/// the manifest's paths (`L/L.data-00000-of-00001`, `R/R.data-00000-of-00001`).
///
/// With --verify, it runs both networks on the inputs of a reference file written by
/// scripts/gaze-model/verify.py and compares the outputs with the original TensorFlow model's.
/// With a video file, it corrects the faces in every frame and reports how many faces it found and
/// how long finding landmarks and correcting took. Otherwise it corrects a fixed pair of eyes in a
/// synthetic picture and checks that only the eye patches changed.
///
/// With --save <folder> after the video, every 150th corrected frame's face is saved before and
/// after the correction, side by side, for a person to judge.
///
/// With --write <file> after the video, the corrected frames are written to a movie file.
///
/// Usage: `lumix-eye-contact-probe <weights folder> [video [--save <folder>] [--write <file>] | --verify <reference.json>]`
@main
struct EyeContactProbe {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let folder = arguments.first else {
            print("usage: lumix-eye-contact-probe <weights folder> [video | --verify <reference.json>]")
            exit(2)
        }
        do {
            let network = try GazeNetwork(folder: URL(fileURLWithPath: folder), manifest: try GazeWeightManifest.bundled())
            let corrector = EyeContactCorrector(network: network)
            if arguments.count > 2, arguments[1] == "--verify" {
                try verify(network, reference: URL(fileURLWithPath: arguments[2]))
            } else if arguments.count > 1 {
                func option(_ name: String) -> URL? {
                    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
                    return URL(fileURLWithPath: arguments[index + 1])
                }
                try await correctVideo(URL(fileURLWithPath: arguments[1]), corrector: corrector, save: option("--save"), write: option("--write"))
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

    struct Reference: Decodable {
        struct Case: Decodable {
            let angle: [Float]
            let leftPatch: [Float]
            let leftAnchors: [Float]
            let rightPatch: [Float]
            let rightAnchors: [Float]
            let leftFlow: [Float]
            let leftLight: [Float]
            let rightFlow: [Float]
            let rightLight: [Float]
        }
        let cases: [Case]
    }

    /// Compares both networks with the original model's outputs; a flow error of 0.01 moves a pixel
    /// by a third of a pixel in the 64-pixel-wide patch.
    static func verify(_ network: GazeNetwork, reference url: URL) throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let reference = try decoder.decode(Reference.self, from: Data(contentsOf: url))
        var worstFlow: Float = 0
        var worstLight: Float = 0
        func largest(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).map { abs($0 - $1) }.max() ?? .infinity }
        for sample in reference.cases {
            let output = try network.run(
                left: (sample.leftPatch, sample.leftAnchors),
                right: (sample.rightPatch, sample.rightAnchors),
                angle: (sample.angle[0], sample.angle[1])
            )
            worstFlow = max(worstFlow, largest(output.left.flow, sample.leftFlow), largest(output.right.flow, sample.rightFlow))
            worstLight = max(worstLight, largest(output.left.light, sample.leftLight), largest(output.right.light, sample.rightLight))
        }
        print("\(reference.cases.count) cases; largest difference: flow \(worstFlow), light \(worstLight)")
        exit(worstFlow < 0.01 && worstLight < 0.01 && !reference.cases.isEmpty ? 0 : 1)
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

    /// Writes the face region of two pictures side by side as PNG.
    static func saveComparison(before: CVPixelBuffer, after: CVPixelBuffer, face: FaceForGaze, to url: URL) {
        let points = face.leftEye.points + face.rightEye.points
        let minX = points.map(\.x).min()!, maxX = points.map(\.x).max()!
        let minY = points.map(\.y).min()!
        let width = (maxX - minX) * 1.6
        let rect = CGRect(x: minX - width * 0.1875, y: minY - width * 0.25, width: width, height: width * 0.5)
        let context = CIContext()
        guard let a = context.createCGImage(CIImage(cvPixelBuffer: before), from: rect.flippedFor(height: Double(CVPixelBufferGetHeight(before)))),
              let b = context.createCGImage(CIImage(cvPixelBuffer: after), from: rect.flippedFor(height: Double(CVPixelBufferGetHeight(after)))) else { return }
        let scale = 3
        let canvas = CGContext(data: nil, width: (a.width * 2 + 8) * scale, height: a.height * scale, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        canvas.interpolationQuality = .high
        canvas.draw(a, in: CGRect(x: 0, y: 0, width: a.width * scale, height: a.height * scale))
        canvas.draw(b, in: CGRect(x: (a.width + 8) * scale, y: 0, width: b.width * scale, height: b.height * scale))
        guard let image = canvas.makeImage(), let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    static func correctVideo(_ url: URL, corrector: EyeContactCorrector, save: URL? = nil, write: URL? = nil) async throws {
        var movie: VideoFileWriter?
        if let save { try FileManager.default.createDirectory(at: save, withIntermediateDirectories: true) }
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
            let keep = save != nil && frames % 150 == 0 && !found.isEmpty ? try copy(picture) : nil
            for face in found {
                let strength = EyeContactCorrector.strength(for: face)
                if strength > 0 { corrected += 1 }
                try corrector.correct(picture, face: face, strength: strength)
            }
            if let keep, let save, let face = found.first {
                saveComparison(before: keep, after: picture, face: face, to: save.appendingPathComponent(String(format: "frame-%05d.png", frames)))
            }
            correctTime += milliseconds(clock.now - found_at)
            if let write {
                if movie == nil {
                    movie = try VideoFileWriter(url: write, size: CGSize(width: CVPixelBufferGetWidth(picture), height: CVPixelBufferGetHeight(picture)))
                }
                movie?.append(picture, at: CMSampleBufferGetPresentationTimeStamp(sample).seconds)
            }
        }
        await movie?.finish()
        print("frames \(frames), faces \(faces), faces corrected \(corrected)")
        if frames > 0 {
            print(String(format: "per frame: finding landmarks %.1f ms, correcting %.1f ms", findTime / Double(frames), correctTime / Double(frames)))
        }
    }
}

extension EyeContactProbe {
    static func copy(_ picture: CVPixelBuffer) throws -> CVPixelBuffer {
        let target = try PixelBufferPool(size: picture.pixelSize).makeBuffer()
        CVPixelBufferLockBaseAddress(picture, .readOnly)
        CVPixelBufferLockBaseAddress(target, [])
        let rows = CVPixelBufferGetHeight(picture)
        let from = CVPixelBufferGetBytesPerRow(picture), to = CVPixelBufferGetBytesPerRow(target)
        for row in 0..<rows {
            memcpy(CVPixelBufferGetBaseAddress(target)! + row * to, CVPixelBufferGetBaseAddress(picture)! + row * from, min(from, to))
        }
        CVPixelBufferUnlockBaseAddress(target, [])
        CVPixelBufferUnlockBaseAddress(picture, .readOnly)
        return target
    }
}

extension CGRect {
    /// The same rectangle measured from the bottom edge, as Core Image measures.
    func flippedFor(height: Double) -> CGRect {
        CGRect(x: minX, y: height - maxY, width: width, height: self.height)
    }
}
