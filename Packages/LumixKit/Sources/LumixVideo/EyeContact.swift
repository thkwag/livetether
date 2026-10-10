import Accelerate
import CoreVideo
import Foundation
import Vision

/// A point in picture pixels, origin at the top-left corner.
public struct PixelPoint: Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// The six landmarks of one eye the gaze model was trained with, in picture pixels: the corner on
/// the picture's left, the two points of the upper lid from left to right, the corner on the
/// picture's right, and the two points of the lower lid from right to left.
public struct EyeOutline: Hashable, Sendable {
    public var points: [PixelPoint]

    public init(points: [PixelPoint]) {
        self.points = points
    }

    /// Derives the six landmarks from an eye contour of any number of points: the corners are the
    /// leftmost and rightmost points, and each lid is sampled at one and two thirds of the way
    /// between them.
    public init?(contour: [PixelPoint]) {
        guard contour.count >= 4,
              let left = contour.min(by: { $0.x < $1.x }),
              let right = contour.max(by: { $0.x < $1.x }),
              right.x - left.x > 1 else { return nil }
        func height(at x: Double, on lid: [PixelPoint]) -> Double? {
            let sorted = ([left, right] + lid).sorted { $0.x < $1.x }
            for (a, b) in zip(sorted, sorted.dropFirst()) where x >= a.x && x <= b.x {
                return b.x - a.x < 1e-9 ? a.y : a.y + (b.y - a.y) * (x - a.x) / (b.x - a.x)
            }
            return nil
        }
        // Points above the line between the corners belong to the upper lid.
        func lineY(_ x: Double) -> Double { left.y + (right.y - left.y) * (x - left.x) / (right.x - left.x) }
        let inner = contour.filter { $0 != left && $0 != right }
        let upper = inner.filter { $0.y < lineY($0.x) }
        let lower = inner.filter { $0.y >= lineY($0.x) }
        let third = left.x + (right.x - left.x) / 3
        let twoThirds = left.x + (right.x - left.x) * 2 / 3
        guard !upper.isEmpty, !lower.isEmpty,
              let u1 = height(at: third, on: upper), let u2 = height(at: twoThirds, on: upper),
              let l2 = height(at: twoThirds, on: lower), let l1 = height(at: third, on: lower) else { return nil }
        points = [
            left, PixelPoint(x: third, y: u1), PixelPoint(x: twoThirds, y: u2),
            right, PixelPoint(x: twoThirds, y: l2), PixelPoint(x: third, y: l1),
        ]
    }

    /// The order the model for this eye expects. The model for the eye on the picture's right was
    /// trained on the mirrored order: right corner first, then the upper lid from right to left.
    func modelOrder(mirrored: Bool) -> [PixelPoint] {
        guard mirrored else { return points }
        return [points[3], points[2], points[1], points[0], points[5], points[4]]
    }
}

/// The face the eye contact correction works on.
public struct FaceForGaze: Sendable {
    public var leftEye: EyeOutline
    public var rightEye: EyeOutline
    /// Head turn and tilt in degrees; nil when not measured.
    public var yaw: Double?
    public var pitch: Double?

    public init(leftEye: EyeOutline, rightEye: EyeOutline, yaw: Double?, pitch: Double?) {
        self.leftEye = leftEye
        self.rightEye = rightEye
        self.yaw = yaw
        self.pitch = pitch
    }
}

/// The rectangle cut around an eye and the model's view of it.
struct EyePatch: Equatable {
    static let height = 48
    static let width = 64
    /// Rows and columns at the patch's edge that are not written back.
    static let margin = (rows: 3, columns: 4)

    /// Top-left corner and size of the patch in picture pixels.
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    /// The six landmarks in patch pixels, in the order the eye's model expects.
    let anchors: [(x: Int, y: Int)]

    static func == (a: EyePatch, b: EyePatch) -> Bool {
        a.x == b.x && a.y == b.y && a.width == b.width && a.height == b.height
            && a.anchors.map { [$0.x, $0.y] } == b.anchors.map { [$0.x, $0.y] }
    }

    /// The rectangle the gaze model was trained on: centered between the corners, one and a half
    /// eye lengths wide and three quarters of that high, with seven twelfths of it above the center.
    init?(eye: EyeOutline, mirrored: Bool) {
        let left = eye.points[0]
        let right = eye.points[3]
        let centerX = (left.x + right.x) * 0.5
        let centerY = (left.y + right.y) * 0.5
        let length = abs(right.x - left.x)
        let halfWidth = length * 3 / 4
        let boxHeight = 1.5 * halfWidth
        let top = Int(centerY - boxHeight * 7 / 12)
        let bottom = Int(centerY + boxHeight * 5 / 12)
        let leftEdge = Int(centerX - halfWidth)
        let rightEdge = Int(centerX + halfWidth)
        guard bottom - top > Self.margin.rows * 2 + 2, rightEdge - leftEdge > Self.margin.columns * 2 + 2 else { return nil }
        x = leftEdge
        y = top
        width = rightEdge - leftEdge
        height = bottom - top
        let scaleX = Double(Self.width) / Double(width)
        let scaleY = Double(Self.height) / Double(height)
        anchors = eye.modelOrder(mirrored: mirrored).map { point in
            (Int((point.x - Double(leftEdge)) * scaleX), Int((point.y - Double(top)) * scaleY))
        }
    }

    func fits(in size: PixelSize) -> Bool {
        x >= 0 && y >= 0 && x + width <= size.width && y + height <= size.height
    }

    /// Twelve maps, two per landmark: the column minus the landmark's x, then the row minus its y,
    /// interleaved per pixel.
    func anchorMaps() -> [Float] {
        var maps = [Float](repeating: 0, count: 12 * Self.height * Self.width)
        for row in 0..<Self.height {
            for column in 0..<Self.width {
                let pixel = (row * Self.width + column) * 12
                for (index, anchor) in anchors.enumerated() {
                    maps[pixel + index * 2] = Float(column - anchor.x)
                    maps[pixel + index * 2 + 1] = Float(row - anchor.y)
                }
            }
        }
        return maps
    }
}

/// The warp and light correction the gaze model's outputs describe, done as the model's training
/// code does them.
public enum GazeWarp {
    /// Moves every pixel by its flow, then mixes it with white by the light weights.
    ///
    /// `image` is height × width × 3, `flow` and `light` are height × width × 2, all row-major.
    /// A flow of ±1 spans half the patch; samples outside the patch take the nearest edge pixel.
    public static func apply(image: [Float], flow: [Float], light: [Float], height: Int, width: Int) -> [Float] {
        var output = [Float](repeating: 0, count: height * width * 3)
        let maxX = width - 1
        let maxY = height - 1
        for row in 0..<height {
            for column in 0..<width {
                let pixel = row * width + column
                let gridX = width > 1 ? -1 + 2 * Float(column) / Float(width - 1) : 0
                let gridY = height > 1 ? -1 + 2 * Float(row) / Float(height - 1) : 0
                let x = 0.5 * (gridX + flow[pixel * 2] + 1) * Float(width)
                let y = 0.5 * (gridY + flow[pixel * 2 + 1] + 1) * Float(height)
                let x0 = min(max(Int(floor(x)), 0), maxX)
                let x1 = min(max(Int(floor(x)) + 1, 0), maxX)
                let y0 = min(max(Int(floor(y)), 0), maxY)
                let y1 = min(max(Int(floor(y)) + 1, 0), maxY)
                let weightA = (Float(x1) - x) * (Float(y1) - y)
                let weightB = (Float(x1) - x) * (y - Float(y0))
                let weightC = (x - Float(x0)) * (Float(y1) - y)
                let weightD = (x - Float(x0)) * (y - Float(y0))
                for channel in 0..<3 {
                    let a = image[(y0 * width + x0) * 3 + channel]
                    let b = image[(y1 * width + x0) * 3 + channel]
                    let c = image[(y0 * width + x1) * 3 + channel]
                    let d = image[(y1 * width + x1) * 3 + channel]
                    let warped = weightA * a + weightB * b + weightC * c + weightD * d
                    output[pixel * 3 + channel] = warped * light[pixel * 2] + light[pixel * 2 + 1]
                }
            }
        }
        return output
    }
}

/// Redirects the eyes of a face toward the camera with the gaze-warping networks.
///
/// The networks were trained on faces looking straight at the screen, so the correction is applied
/// in full only while the face points at the camera and fades out as it turns away.
public final class EyeContactCorrector: Sendable {
    private let network: GazeNetwork

    /// The redirection angle in degrees: vertical (positive moves the gaze up), then horizontal.
    public let angle: (vertical: Float, horizontal: Float)

    public init(network: GazeNetwork, angle: (vertical: Float, horizontal: Float) = (15, 0)) {
        self.network = network
        self.angle = angle
    }

    /// How strongly to correct a face with this head pose: 1 straight ahead, falling to 0 at
    /// 20 degrees of turn or tilt.
    public static func strength(for face: FaceForGaze) -> Double {
        let turn = max(abs(face.yaw ?? 0), abs(face.pitch ?? 0))
        return min(1, max(0, (20 - turn) / 10))
    }

    /// Corrects the eyes in place, mixing the corrected eyes with the original by `strength`.
    public func correct(_ picture: CVPixelBuffer, face: FaceForGaze, strength: Double) throws(VideoError) {
        guard strength > 0 else { return }
        try picture.requireBGRA()
        let size = picture.pixelSize
        // The network "L" works on the eye on the picture's right, with its landmarks mirrored.
        guard let eyeL = EyePatch(eye: face.rightEye, mirrored: true),
              let eyeR = EyePatch(eye: face.leftEye, mirrored: false),
              eyeL.fits(in: size), eyeR.fits(in: size) else { return }
        try picture.withLockedBase(readOnly: false) { (base, rowBytes) throws(VideoError) in
            let imageL = Self.read(eyeL, base: base, rowBytes: rowBytes)
            let imageR = Self.read(eyeR, base: base, rowBytes: rowBytes)
            let outputs: (left: GazeNetwork.Output, right: GazeNetwork.Output)
            do {
                outputs = try network.run(
                    left: (imageL, eyeL.anchorMaps()),
                    right: (imageR, eyeR.anchorMaps()),
                    angle: (angle.vertical, angle.horizontal)
                )
            } catch {
                throw .detectionFailed("Eye contact network: \(error)")
            }
            for (patch, image, output) in [(eyeL, imageL, outputs.left), (eyeR, imageR, outputs.right)] {
                let corrected = GazeWarp.apply(image: image, flow: output.flow, light: output.light, height: EyePatch.height, width: EyePatch.width)
                Self.write(corrected, into: patch, base: base, rowBytes: rowBytes, strength: Float(strength))
            }
        }
    }

    // MARK: - Pixels

    /// The patch's pixels scaled to the model's size with bilinear sampling at pixel centers, as
    /// OpenCV resizes, in BGR order from 0 to 1.
    static func read(_ patch: EyePatch, base: UnsafeMutableRawPointer, rowBytes: Int) -> [Float] {
        var output = [Float](repeating: 0, count: EyePatch.height * EyePatch.width * 3)
        let scaleX = Double(patch.width) / Double(EyePatch.width)
        let scaleY = Double(patch.height) / Double(EyePatch.height)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for row in 0..<EyePatch.height {
            let sourceY = min(max((Double(row) + 0.5) * scaleY - 0.5, 0), Double(patch.height - 1))
            let y0 = Int(sourceY)
            let y1 = min(y0 + 1, patch.height - 1)
            let fy = Float(sourceY - Double(y0))
            for column in 0..<EyePatch.width {
                let sourceX = min(max((Double(column) + 0.5) * scaleX - 0.5, 0), Double(patch.width - 1))
                let x0 = Int(sourceX)
                let x1 = min(x0 + 1, patch.width - 1)
                let fx = Float(sourceX - Double(x0))
                for channel in 0..<3 {
                    func value(_ x: Int, _ y: Int) -> Float {
                        Float(bytes[(patch.y + y) * rowBytes + (patch.x + x) * 4 + channel])
                    }
                    let top = value(x0, y0) * (1 - fx) + value(x1, y0) * fx
                    let bottom = value(x0, y1) * (1 - fx) + value(x1, y1) * fx
                    output[(row * EyePatch.width + column) * 3 + channel] = (top * (1 - fy) + bottom * fy) / 255
                }
            }
        }
        return output
    }

    /// Scales the corrected patch back to the eye's size and writes it, leaving the patch's edge
    /// rows and columns as they were.
    static func write(_ corrected: [Float], into patch: EyePatch, base: UnsafeMutableRawPointer, rowBytes: Int, strength: Float) {
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let scaleX = Double(EyePatch.width) / Double(patch.width)
        let scaleY = Double(EyePatch.height) / Double(patch.height)
        for y in EyePatch.margin.rows..<(patch.height - EyePatch.margin.rows) {
            let sourceY = min(max((Double(y) + 0.5) * scaleY - 0.5, 0), Double(EyePatch.height - 1))
            let y0 = Int(sourceY)
            let y1 = min(y0 + 1, EyePatch.height - 1)
            let fy = Float(sourceY - Double(y0))
            for x in EyePatch.margin.columns..<(patch.width - EyePatch.margin.columns) {
                let sourceX = min(max((Double(x) + 0.5) * scaleX - 0.5, 0), Double(EyePatch.width - 1))
                let x0 = Int(sourceX)
                let x1 = min(x0 + 1, EyePatch.width - 1)
                let fx = Float(sourceX - Double(x0))
                let offset = (patch.y + y) * rowBytes + (patch.x + x) * 4
                for channel in 0..<3 {
                    func value(_ px: Int, _ py: Int) -> Float { corrected[(py * EyePatch.width + px) * 3 + channel] }
                    let top = value(x0, y0) * (1 - fx) + value(x1, y0) * fx
                    let bottom = value(x0, y1) * (1 - fx) + value(x1, y1) * fx
                    let new = min(max((top * (1 - fy) + bottom * fy) * 255, 0), 255)
                    let old = Float(bytes[offset + channel])
                    bytes[offset + channel] = UInt8((old + (new - old) * strength).rounded())
                }
            }
        }
    }
}

/// Finds the faces whose eyes the correction can work on.
public final class FaceLandmarkFinder: Sendable {
    /// The width of the grayscale copy the landmarks are found on.
    public static let analysisWidth = 640

    public init() {}

    public func faces(in picture: CVPixelBuffer) throws(VideoError) -> [FaceForGaze] {
        let gray = try PersonDetector.grayscaleCopy(of: picture, width: Self.analysisWidth)
        let request = VNDetectFaceLandmarksRequest()
        do {
            try VNImageRequestHandler(cvPixelBuffer: gray, options: [:]).perform([request])
        } catch {
            throw .detectionFailed(error.localizedDescription)
        }
        let size = picture.pixelSize
        return (request.results ?? []).compactMap { face in
            guard let landmarks = face.landmarks,
                  let left = landmarks.leftEye, let right = landmarks.rightEye else { return nil }
            func outline(_ region: VNFaceLandmarkRegion2D) -> EyeOutline? {
                let points = region.pointsInImage(imageSize: CGSize(width: size.width, height: size.height))
                    .map { PixelPoint(x: Double($0.x), y: Double(size.height) - Double($0.y)) }
                return EyeOutline(contour: points)
            }
            // Vision names the eyes from the person's side; the correction names them by the picture.
            guard let personLeft = outline(left), let personRight = outline(right) else { return nil }
            let onLeft = personLeft.points[0].x < personRight.points[0].x ? personLeft : personRight
            let onRight = onLeft == personLeft ? personRight : personLeft
            return FaceForGaze(
                leftEye: onLeft,
                rightEye: onRight,
                yaw: face.yaw.map { $0.doubleValue * 180 / .pi },
                pitch: face.pitch.map { $0.doubleValue * 180 / .pi }
            )
        }
    }
}
