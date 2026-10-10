import Accelerate
import CoreVideo
import Foundation
import Vision

/// Finds people in a picture for the automatic framing.
///
/// The picture is reduced to a small grayscale copy first; people and faces are found in that copy,
/// and their positions are returned as fractions of the picture, which hold at any size.
public final class PersonDetector: Sendable {
    /// The width of the grayscale copy the detection runs on.
    public static let analysisWidth = 320

    public init() {}

    public func detect(in picture: CVPixelBuffer) throws(VideoError) -> [FramingSubject] {
        let gray = try Self.grayscaleCopy(of: picture)
        let bodies = VNDetectHumanRectanglesRequest()
        bodies.upperBodyOnly = true
        let faces = VNDetectFaceLandmarksRequest()
        do {
            try VNImageRequestHandler(cvPixelBuffer: gray, options: [:]).perform([bodies, faces])
        } catch {
            throw .detectionFailed(error.localizedDescription)
        }
        let bodyRects = (bodies.results ?? []).map { Self.topLeft($0.boundingBox) }
        let measuredFaces = (faces.results ?? []).map { (rect: Self.topLeft($0.boundingBox), facing: Self.facing(of: $0)) }
        return Self.subjects(bodies: bodyRects, faces: measuredFaces)
    }

    /// Pairs each face with the body that contains its center; a face without a body stands for a
    /// person whose body is out of view, and gets a body box around the face.
    static func subjects(bodies: [NormalizedRect], faces: [(rect: NormalizedRect, facing: Double?)]) -> [FramingSubject] {
        var subjects = bodies.map { FramingSubject(body: $0) }
        for face in faces {
            if let index = subjects.indices.first(where: { subjects[$0].face == nil && contains(subjects[$0].body, x: face.rect.midX, y: face.rect.midY) }) {
                subjects[index].face = face.rect
                subjects[index].facing = face.facing
            } else {
                let body = NormalizedRect(
                    x: face.rect.minX - face.rect.width * 0.8,
                    y: face.rect.minY - face.rect.height * 0.3,
                    width: face.rect.width * 2.6,
                    height: face.rect.height * 3.2
                )
                subjects.append(FramingSubject(body: body, face: face.rect, facing: face.facing))
            }
        }
        return subjects
    }

    private static func contains(_ rect: NormalizedRect, x: Double, y: Double) -> Bool {
        x >= rect.minX && x <= rect.maxX && y >= rect.minY && y <= rect.maxY
    }

    /// Vision measures from the bottom-left corner; framing measures from the top-left.
    private static func topLeft(_ box: CGRect) -> NormalizedRect {
        NormalizedRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }

    /// How far the nose sits beside the point between the eyes, against the distance between the
    /// eyes: the nose moves toward the side the face turns to. Scaled so a strong turn reads ±1.
    private static func facing(of face: VNFaceObservation) -> Double? {
        guard let landmarks = face.landmarks,
              let nose = landmarks.nose.map(centroid),
              let left = landmarks.leftEye.map(centroid),
              let right = landmarks.rightEye.map(centroid) else { return nil }
        let eyeDistance = abs(right.x - left.x)
        guard eyeDistance > 0.01 else { return nil }
        let offset = (nose.x - (left.x + right.x) / 2) / eyeDistance
        return min(1, max(-1, offset / 0.3))
    }

    private static func centroid(_ region: VNFaceLandmarkRegion2D) -> CGPoint {
        let points = region.normalizedPoints
        guard !points.isEmpty else { return .zero }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    /// A one-channel copy of the picture, `width` wide, with the picture's aspect ratio.
    static func grayscaleCopy(of picture: CVPixelBuffer, width requestedWidth: Int = analysisWidth) throws(VideoError) -> CVPixelBuffer {
        try picture.requireBGRA()
        let size = picture.pixelSize
        let width = min(requestedWidth, size.width)
        let height = max(1, size.height * width / max(1, size.width))
        var small: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_OneComponent8, nil, &small)
        guard status == kCVReturnSuccess, let small else { throw .bufferCreationFailed(status) }
        var scaled = [UInt8](repeating: 0, count: width * height * 4)
        try picture.withLockedBase(readOnly: true) { (base, rowBytes) throws(VideoError) in
            var input = vImage_Buffer(data: base, height: vImagePixelCount(size.height), width: vImagePixelCount(size.width), rowBytes: rowBytes)
            let result = scaled.withUnsafeMutableBytes { bytes -> vImage_Error in
                var output = vImage_Buffer(data: bytes.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                return vImageScale_ARGB8888(&input, &output, nil, vImage_Flags(kvImageNoFlags))
            }
            guard result == kvImageNoError else { throw .scaleFailed(result) }
        }
        try small.withLockedBase(readOnly: false) { (base, rowBytes) throws(VideoError) in
            let row = UnsafeMutableRawPointer(base)
            for y in 0..<height {
                let target = row.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    let pixel = (y * width + x) * 4
                    // BGRA memory order; Rec. 601 luma in integer arithmetic.
                    let luma = (29 * Int(scaled[pixel]) + 150 * Int(scaled[pixel + 1]) + 77 * Int(scaled[pixel + 2])) >> 8
                    target[x] = UInt8(luma)
                }
            }
        }
        return small
    }
}
