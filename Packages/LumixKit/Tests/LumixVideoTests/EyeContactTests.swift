import CoreVideo
import Foundation
@testable import LumixVideo
import Testing

@Suite("Eye contact")
struct EyeContactTests {
    struct Fixture: Decodable {
        struct Case: Decodable {
            let height: Int
            let width: Int
            let image: [Float]
            let flow: [Float]
            let light: [Float]
            let expected: [Float]
        }
        let cases: [Case]
    }

    @Test("The warp and light correction match the model's training code")
    func warpMatchesReference() throws {
        let url = try #require(Bundle.module.url(forResource: "gaze-warp", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        #expect(fixture.cases.count == 4)
        for (index, sample) in fixture.cases.enumerated() {
            let result = GazeWarp.apply(image: sample.image, flow: sample.flow, light: sample.light, height: sample.height, width: sample.width)
            let difference = zip(result, sample.expected).map { abs($0 - $1) }.max() ?? .infinity
            #expect(difference < 1e-5, "case \(index): largest difference \(difference)")
        }
    }

    static let contour: [PixelPoint] = [
        PixelPoint(x: 100, y: 200), PixelPoint(x: 110, y: 194), PixelPoint(x: 120, y: 192), PixelPoint(x: 130, y: 194),
        PixelPoint(x: 140, y: 199), PixelPoint(x: 130, y: 204), PixelPoint(x: 120, y: 206), PixelPoint(x: 110, y: 204),
    ]

    @Test("Six landmarks come from a contour: the corners, then the lids at one and two thirds")
    func outlineFromContour() throws {
        let eye = try #require(EyeOutline(contour: Self.contour))
        let expected: [(Double, Double)] = [(100, 200), (113.333, 193.333), (126.667, 193.333), (140, 199), (126.667, 204.667), (113.333, 204.667)]
        for (point, (x, y)) in zip(eye.points, expected) {
            #expect(abs(point.x - x) < 0.01 && abs(point.y - y) < 0.01, "\(point) is not (\(x), \(y))")
        }
        #expect(EyeOutline(contour: Array(Self.contour.prefix(3))) == nil)
    }

    @Test("The patch is cut and the anchors placed as the model's training code does")
    func patchGeometry() throws {
        let eye = try #require(EyeOutline(contour: Self.contour))
        let patch = try #require(EyePatch(eye: eye, mirrored: false))
        // Eye length 40: half width 30, height 45, 26.25 above the center (120, 199.5), 18.75 below.
        #expect(patch.x == 90 && patch.y == 173 && patch.width == 60 && patch.height == 45)
        #expect(patch.anchors[0].x == Int((100.0 - 90) * 64 / 60) && patch.anchors[0].y == Int((200.0 - 173) * 48 / 45))
        let mirrored = try #require(EyePatch(eye: eye, mirrored: true))
        #expect(mirrored.anchors[0].x == patch.anchors[3].x && mirrored.anchors[4].x == patch.anchors[5].x)
        let maps = patch.anchorMaps()
        let plane = 48 * 64
        // At row 10, column 20: column minus the first landmark's x, row minus its y.
        #expect(maps[10 * 64 + 20] == Float(20 - patch.anchors[0].x))
        #expect(maps[plane + 10 * 64 + 20] == Float(10 - patch.anchors[0].y))
    }

    @Test("The correction is full straight ahead and fades out by 20 degrees of turn")
    func strength() throws {
        let eye = try #require(EyeOutline(contour: Self.contour))
        func face(_ yaw: Double?, _ pitch: Double?) -> FaceForGaze { FaceForGaze(leftEye: eye, rightEye: eye, yaw: yaw, pitch: pitch) }
        #expect(EyeContactCorrector.strength(for: face(0, 0)) == 1)
        #expect(EyeContactCorrector.strength(for: face(10, 0)) == 1)
        #expect(EyeContactCorrector.strength(for: face(15, 0)) == 0.5)
        #expect(EyeContactCorrector.strength(for: face(0, -25)) == 0)
        #expect(EyeContactCorrector.strength(for: face(nil, nil)) == 1)
    }

    @Test("Writing a patch back leaves its edge and, at zero strength, everything untouched")
    func writeBack() throws {
        let eye = try #require(EyeOutline(contour: Self.contour))
        let patch = try #require(EyePatch(eye: eye, mirrored: false))
        let picture = try PixelBufferPool(size: PixelSize(width: 256, height: 256)).makeBuffer()
        try picture.withLockedBase(readOnly: false) { (base, rowBytes) throws(VideoError) in
            memset(base, 0x40, rowBytes * 256)
            let white = [Float](repeating: 1, count: 48 * 64 * 3)
            EyeContactCorrector.write(white, into: patch, base: base, rowBytes: rowBytes, strength: 0)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            #expect((0..<(rowBytes * 256)).allSatisfy { bytes[$0] == 0x40 })
            EyeContactCorrector.write(white, into: patch, base: base, rowBytes: rowBytes, strength: 1)
            let inside = (patch.y + 10) * rowBytes + (patch.x + 10) * 4
            let edge = (patch.y + 1) * rowBytes + (patch.x + 10) * 4
            #expect(bytes[inside] == 255 && bytes[edge] == 0x40)
        }
    }
}
