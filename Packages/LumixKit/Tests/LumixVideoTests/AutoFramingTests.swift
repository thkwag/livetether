import CoreVideo
import Foundation
import LumixTestSupport
@testable import LumixVideo
import Testing

@Suite("Auto framing")
struct AutoFramingTests {
    static let source = PixelSize(width: 1280, height: 960)
    static let output = PixelSize(width: 1920, height: 1080)
    static let frame = 1.0 / 30

    /// Runs the framer at 30 frames a second from `start` for `seconds`, reporting `subjects` five
    /// times a second, and returns every crop.
    static func run(_ framer: inout AutoFramer, from start: Double, seconds: Double, subjects: (Double) -> [FramingSubject]) -> [PixelRect] {
        var crops: [PixelRect] = []
        var time = start
        var nextDetection = start
        while time < start + seconds {
            if time >= nextDetection {
                framer.observe(subjects(time), at: time)
                nextDetection += 0.2
            }
            crops.append(framer.crop(at: time))
            time += frame
        }
        return crops
    }

    static func person(x: Double, y: Double, width: Double, height: Double, facing: Double? = nil) -> FramingSubject {
        let body = NormalizedRect(x: x, y: y, width: width, height: height)
        let face = NormalizedRect(x: x + width * 0.35, y: y + height * 0.05, width: width * 0.3, height: height * 0.3)
        return FramingSubject(body: body, face: face, facing: facing)
    }

    static func randomPerson(_ generator: inout SeededGenerator, facing: Double? = nil) -> FramingSubject {
        let width = Double.random(in: 0.15...0.4, using: &generator)
        let height = Double.random(in: 0.25...0.6, using: &generator)
        return person(
            x: Double.random(in: 0...(1 - width), using: &generator),
            y: Double.random(in: 0...(1 - height), using: &generator),
            width: width,
            height: height,
            facing: facing
        )
    }

    static func pixels(_ rect: NormalizedRect) -> (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        (rect.minX * Double(source.width), rect.minY * Double(source.height), rect.maxX * Double(source.width), rect.maxY * Double(source.height))
    }

    @Test("The crop stays inside the picture and keeps the output's aspect ratio")
    func cropBounds() {
        forEachSeed(150) { seed, generator in
            let source = PixelSize(width: Int.random(in: 320...1920, using: &generator), height: Int.random(in: 240...1440, using: &generator))
            let output = [PixelSize(width: 1920, height: 1080), PixelSize(width: 1280, height: 960)].randomElement(using: &generator)!
            var framer = AutoFramer(source: source, output: output)
            var people = (0..<Int.random(in: 0...3, using: &generator)).map { _ in Self.randomPerson(&generator) }
            let crops = Self.run(&framer, from: 0, seconds: 4) { time in
                if time > 2 { people = people.map { _ in Self.randomPerson(&generator) } }
                return people
            }
            let aspect = Double(output.width) / Double(output.height)
            for crop in crops {
                #expect(crop.x >= 0 && crop.y >= 0, "seed \(seed): \(crop)")
                #expect(crop.x + crop.width <= source.width && crop.y + crop.height <= source.height, "seed \(seed): \(crop) in \(source)")
                #expect(abs(Double(crop.width) - Double(crop.height) * aspect) <= 1.5, "seed \(seed): \(crop) for \(output)")
            }
        }
    }

    @Test("A person who stays still ends up inside the crop with the eyes in the upper third")
    func stillPersonFramed() throws {
        try forEachSeed(150) { seed, generator in
            let subject = Self.randomPerson(&generator)
            var framer = AutoFramer(source: Self.source, output: Self.output)
            let crop = try #require(Self.run(&framer, from: 0, seconds: 8) { _ in [subject] }.last)
            let body = Self.pixels(subject.body)
            #expect(Double(crop.x) <= body.minX + 1 && Double(crop.x + crop.width) >= body.maxX - 1, "seed \(seed): \(crop) misses \(body)")
            #expect(Double(crop.y) <= body.minY + 1, "seed \(seed): \(crop) cuts the head of \(body)")
            // A crop at an edge, or at full height because the shot did not fit, cannot place the eyes.
            let touchesEdge = crop.y == 0 || crop.y + crop.height == Self.source.height || crop.height == 720
            if !touchesEdge, let face = subject.face {
                let eyes = (face.minY + face.height * 0.42) * Double(Self.source.height)
                let share = (eyes - Double(crop.y)) / Double(crop.height)
                #expect(abs(share - 1.0 / 3.0) < 0.06, "seed \(seed): eyes at \(share) of \(crop)")
            }
        }
    }

    @Test("The crop never moves or zooms faster than the speed limits")
    func speedLimits() {
        let parameters = FramingParameters()
        forEachSeed(150) { seed, generator in
            var framer = AutoFramer(source: Self.source, output: Self.output)
            var subject = Self.randomPerson(&generator)
            let crops = Self.run(&framer, from: 0, seconds: 6) { _ in
                if Double.random(in: 0...1, using: &generator) < 0.3 { subject = Self.randomPerson(&generator) }
                return [subject]
            }
            for (previous, next) in zip(crops, crops.dropFirst()) {
                let pan = abs(Double(next.x + next.width / 2) - Double(previous.x + previous.width / 2))
                let zoom = abs(Double(next.height - previous.height))
                #expect(pan <= parameters.maximumPanSpeed * Double(previous.width) * Self.frame + 2, "seed \(seed): pan \(pan) from \(previous) to \(next)")
                #expect(zoom <= parameters.maximumZoomSpeed * Double(previous.height) * Self.frame + 2, "seed \(seed): zoom \(zoom) from \(previous) to \(next)")
            }
        }
    }

    @Test("A face turned to one side gets room on that side; a face looking ahead gets none")
    func lookRoom() throws {
        for facing in [-1.0, -0.6, 0.6, 1.0, 0.0, 0.1, -0.1] {
            let subject = Self.person(x: 0.4, y: 0.3, width: 0.2, height: 0.35, facing: facing)
            var framer = AutoFramer(source: Self.source, output: Self.output)
            let crop = try #require(Self.run(&framer, from: 0, seconds: 8) { _ in [subject] }.last)
            let shift = Double(crop.x) + Double(crop.width) / 2 - subject.body.midX * Double(Self.source.width)
            if abs(facing) > FramingParameters().facingDeadZone {
                #expect(shift * facing > 0, "facing \(facing): crop center moved by \(shift)")
            } else {
                #expect(abs(shift) <= Double(crop.width) * 0.05, "facing \(facing): crop center moved by \(shift)")
            }
        }
    }

    @Test("A person who leaves is held for a moment, then the full picture returns")
    func holdThenRelease() throws {
        let subject = Self.person(x: 0.6, y: 0.2, width: 0.2, height: 0.35)
        var framer = AutoFramer(source: Self.source, output: Self.output)
        let framed = try #require(Self.run(&framer, from: 0, seconds: 6) { _ in [subject] }.last)
        let held = try #require(Self.run(&framer, from: 6, seconds: 1.0) { _ in [] }.last)
        #expect(held == framed, "the composition was not held: \(framed) became \(held)")
        let released = try #require(Self.run(&framer, from: 7, seconds: 10) { _ in [] }.last)
        #expect(released == PixelRect(x: 0, y: 120, width: 1280, height: 720), "the full picture did not return: \(released)")
    }

    @Test("Small movements of a framed person do not move the crop")
    func jitterIgnored() throws {
        forEachSeed(60) { seed, generator in
            let still = Self.randomPerson(&generator)
            var framer = AutoFramer(source: Self.source, output: Self.output)
            _ = Self.run(&framer, from: 0, seconds: 8) { _ in [still] }
            let crops = Self.run(&framer, from: 8, seconds: 4) { _ in
                var moved = still
                moved.body.x += Double.random(in: -0.008...0.008, using: &generator)
                moved.body.y += Double.random(in: -0.008...0.008, using: &generator)
                return [moved]
            }
            #expect(Set(crops).count == 1, "seed \(seed): the crop moved \(Set(crops).count - 1) times")
        }
    }

    @Test("A newcomer joins the composition only after the join delay")
    func joinDelay() throws {
        let first = Self.person(x: 0.1, y: 0.3, width: 0.2, height: 0.35)
        let second = Self.person(x: 0.7, y: 0.3, width: 0.2, height: 0.35)
        var framer = AutoFramer(source: Self.source, output: Self.output)
        let alone = try #require(Self.run(&framer, from: 0, seconds: 8) { _ in [first] }.last)
        let early = try #require(Self.run(&framer, from: 8, seconds: 0.4) { _ in [first, second] }.last)
        #expect(early == alone, "the newcomer moved the crop before the join delay: \(alone) became \(early)")
        let together = try #require(Self.run(&framer, from: 8.4, seconds: 8) { _ in [first, second] }.last)
        let right = Self.pixels(second.body).maxX
        #expect(Double(together.x + together.width) >= right - 1, "the newcomer is not in \(together)")
    }

    @Test("A face is paired with the body around it; a face alone gets a body of its own")
    func facePairing() {
        let body = NormalizedRect(x: 0.2, y: 0.2, width: 0.3, height: 0.5)
        let inside = NormalizedRect(x: 0.3, y: 0.25, width: 0.1, height: 0.12)
        let alone = NormalizedRect(x: 0.75, y: 0.3, width: 0.1, height: 0.12)
        let subjects = PersonDetector.subjects(bodies: [body], faces: [(inside, 0.5), (alone, nil)])
        #expect(subjects.count == 2)
        #expect(subjects[0].face == inside && subjects[0].facing == 0.5)
        #expect(subjects[1].face == alone && subjects[1].body.overlap(alone) > 0)
    }

    @Test("Cropping takes exactly the requested part of the picture")
    func cropPixels() throws {
        let pool = try PixelBufferPool(size: PixelSize(width: 200, height: 100))
        let source = try pool.makeBuffer()
        // Left half blue, right half red, in BGRA memory order.
        try source.withLockedBase(readOnly: false) { (base, rowBytes) throws(VideoError) in
            for y in 0..<100 {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<200 {
                    let pixel = x < 100 ? [UInt8(255), 0, 0, 255] : [UInt8(0), 0, 255, 255]
                    for channel in 0..<4 { row[x * 4 + channel] = pixel[channel] }
                }
            }
        }
        let target = try PixelBufferPool(size: PixelSize(width: 160, height: 160)).makeBuffer()
        try FrameCropper.crop(source, to: PixelRect(x: 110, y: 10, width: 80, height: 80), into: target)
        var allRed = true
        try target.withLockedBase(readOnly: true) { (base, rowBytes) throws(VideoError) in
            for y in 0..<160 {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<160 where row[x * 4] > 8 || row[x * 4 + 2] < 247 {
                    allRed = false
                }
            }
        }
        #expect(allRed)
        #expect(throws: VideoError.cropOutOfBounds) {
            try FrameCropper.crop(source, to: PixelRect(x: 150, y: 0, width: 80, height: 80), into: target)
        }
    }

    @Test("Detection reduces the picture to a small grayscale copy and finds nobody in a plain picture")
    func detectionOnPlainPicture() throws {
        let picture = try PixelBufferPool(size: PixelSize(width: 1280, height: 960)).makeBuffer()
        try picture.withLockedBase(readOnly: false) { (base, rowBytes) throws(VideoError) in
            memset(base, 0x80, rowBytes * 960)
        }
        let gray = try PersonDetector.grayscaleCopy(of: picture)
        #expect(gray.pixelSize == PixelSize(width: 320, height: 240))
        #expect(CVPixelBufferGetPixelFormatType(gray) == kCVPixelFormatType_OneComponent8)
        #expect(try PersonDetector().detect(in: picture).isEmpty)
    }

    @Test("The shot sets the crop's height from the face: 3.6 faces for head and shoulders, 5.5 for upper body")
    func shotSize() throws {
        // A small face high in the picture, with no body found: the body box is only estimated.
        let face = NormalizedRect(x: 0.45, y: 0.2, width: 0.1, height: 0.12)
        let subject = FramingSubject(body: NormalizedRect(x: 0.4, y: 0.15, width: 0.2, height: 0.3), face: face)
        var heights: [FramingShot: Int] = [:]
        for shot in FramingShot.allCases {
            var parameters = FramingParameters()
            parameters.shot = shot
            var framer = AutoFramer(source: Self.source, output: Self.output, parameters: parameters)
            let crop = try #require(Self.run(&framer, from: 0, seconds: 10) { _ in [subject] }.last)
            let expected = face.height * Double(Self.source.height) * shot.faceHeights
            #expect(abs(Double(crop.height) - expected) <= 2, "\(shot): \(crop.height) rows, expected \(expected)")
            let faceX = face.midX * Double(Self.source.width), faceTop = face.minY * Double(Self.source.height)
            #expect(Double(crop.x) < faceX && Double(crop.x + crop.width) > faceX && Double(crop.y) <= faceTop, "\(shot): \(crop)")
            let hairTop = faceTop - face.height * Double(Self.source.height) * AutoFramer.hairShare
            #expect(crop.y == 0 || Double(crop.y) <= hairTop + 1, "\(shot): \(crop) cuts the hair above \(hairTop)")
            heights[shot] = crop.height
        }
        #expect((heights[.upperBody] ?? 0) > (heights[.headAndShoulders] ?? 0))
    }

    @Test("A face too near the picture's bottom for the shot leaves the picture at full height")
    func shotDoesNotFit() throws {
        let face = NormalizedRect(x: 0.45, y: 0.78, width: 0.1, height: 0.15)
        let subject = FramingSubject(body: NormalizedRect(x: 0.4, y: 0.72, width: 0.2, height: 0.28), face: face)
        var framer = AutoFramer(source: Self.source, output: Self.output)
        let crop = try #require(Self.run(&framer, from: 0, seconds: 10) { _ in [subject] }.last)
        #expect(crop.height == 720, "\(crop)")
    }

    @Test("A large face keeps room for the hair above it")
    func hairRoom() throws {
        // A close-up: the face is 40% of the picture's height, so the crop falls back to full height.
        let face = NormalizedRect(x: 0.35, y: 0.25, width: 0.3, height: 0.4)
        let subject = FramingSubject(body: NormalizedRect(x: 0.25, y: 0.2, width: 0.5, height: 0.8), face: face)
        var framer = AutoFramer(source: Self.source, output: Self.output)
        let crop = try #require(Self.run(&framer, from: 0, seconds: 10) { _ in [subject] }.last)
        let hairTop = (face.minY - face.height * AutoFramer.hairShare) * Double(Self.source.height)
        #expect(Double(crop.y) <= hairTop + 1, "\(crop) cuts the hair above \(hairTop)")
    }
}
