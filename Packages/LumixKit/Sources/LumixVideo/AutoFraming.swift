import Foundation

/// A rectangle in the unit square of a picture, origin at the top-left corner.
public struct NormalizedRect: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }

    public func union(_ other: NormalizedRect) -> NormalizedRect {
        let left = min(minX, other.minX)
        let top = min(minY, other.minY)
        return NormalizedRect(x: left, y: top, width: max(maxX, other.maxX) - left, height: max(maxY, other.maxY) - top)
    }

    /// The shared area divided by the combined area; 0 when the rectangles do not meet.
    public func overlap(_ other: NormalizedRect) -> Double {
        let width = min(maxX, other.maxX) - max(minX, other.minX)
        let height = min(maxY, other.maxY) - max(minY, other.minY)
        guard width > 0, height > 0 else { return 0 }
        let shared = width * height
        return shared / (self.width * self.height + other.width * other.height - shared)
    }
}

/// One person found in a picture.
public struct FramingSubject: Hashable, Sendable {
    /// The upper body, including the head.
    public var body: NormalizedRect
    public var face: NormalizedRect?
    /// Which way the face points across the picture: −1 toward the left edge, 1 toward the right
    /// edge, 0 straight at the camera; `nil` when no face was measured.
    public var facing: Double?

    public init(body: NormalizedRect, face: NormalizedRect? = nil, facing: Double? = nil) {
        self.body = body
        self.face = face
        self.facing = facing
    }
}

/// How the automatic framing composes and moves the crop.
public struct FramingParameters: Sendable, Equatable {
    /// The crop is never smaller than the full picture divided by this.
    public var maximumZoom = 2.0
    /// The people fill at most this share of the crop's height and width.
    public var subjectHeightShare = 0.75
    public var subjectWidthShare = 0.8
    /// The eyes sit this far down from the crop's top, as a share of its height.
    public var eyeLine = 1.0 / 3.0
    /// Extra room on the side a face points to, as a share of the crop's width at full turn.
    public var lookRoom = 0.12
    /// Facing values this close to 0 count as looking at the camera.
    public var facingDeadZone = 0.2
    /// A new composition that differs from the current one by less than this share of the crop is ignored.
    public var settleShare = 0.05
    /// Time constants of the approach to the composition, in seconds.
    public var panTime = 0.7
    public var zoomTime = 1.4
    /// Speed limits: crop widths per second for panning, relative size per second for zooming.
    public var maximumPanSpeed = 0.6
    public var maximumZoomSpeed = 0.5
    /// The crop always moves at least this fast, as a share of its height per second, so the slow
    /// end of the approach finishes instead of trailing on for seconds.
    public var minimumSpeed = 0.04
    /// A newly seen person joins the composition after this many seconds.
    public var joinDelay = 0.6
    /// A person not seen for this many seconds leaves the composition.
    public var forgetDelay = 1.0
    /// With nobody in view, the last composition is kept this long before returning to the full picture.
    public var holdTime = 1.5

    public init() {}
}

/// Keeps the people in front of the camera framed: it tracks the people a detector reports and
/// moves a crop of the picture smoothly toward a composition around them.
///
/// The crop always has the output's aspect ratio and lies inside the picture. Positions are in
/// picture pixels; times are in seconds on any monotonic clock.
public struct AutoFramer: Sendable {
    private struct Track {
        var body: NormalizedRect
        var face: NormalizedRect?
        var facing: Double?
        var firstSeen: Double
        var lastSeen: Double
    }

    /// A crop as its center and height; the width follows from the output's aspect ratio.
    private struct Composition: Equatable {
        var centerX: Double
        var centerY: Double
        var height: Double
    }

    public let source: PixelSize
    public let output: PixelSize
    public let parameters: FramingParameters

    private var tracks: [Track] = []
    private var lastSubjectTime: Double?
    private var target: Composition
    private var current: Composition
    private var lastTime: Double?

    public init(source: PixelSize, output: PixelSize, parameters: FramingParameters = FramingParameters()) {
        self.source = source
        self.output = output
        self.parameters = parameters
        let full = Self.fullComposition(source: source, output: output)
        target = full
        current = full
    }

    private var aspect: Double { Double(output.width) / Double(output.height) }

    /// Records the people found in the picture taken at `time`.
    public mutating func observe(_ subjects: [FramingSubject], at time: Double) {
        var matched = Set<Int>()
        for subject in subjects {
            let best = tracks.indices
                .filter { !matched.contains($0) }
                .max { tracks[$0].body.overlap(subject.body) < tracks[$1].body.overlap(subject.body) }
            if let index = best, tracks[index].body.overlap(subject.body) > 0.2 {
                tracks[index].body = subject.body
                tracks[index].face = subject.face
                tracks[index].facing = subject.facing
                tracks[index].lastSeen = time
                matched.insert(index)
            } else {
                tracks.append(Track(body: subject.body, face: subject.face, facing: subject.facing, firstSeen: time, lastSeen: time))
                matched.insert(tracks.count - 1)
            }
        }
        tracks.removeAll { time - $0.lastSeen > parameters.forgetDelay }
    }

    /// Moves the crop toward the composition for `time` and returns it.
    public mutating func crop(at time: Double) -> PixelRect {
        let elapsed = lastTime.map { max(0, min(time - $0, 0.5)) } ?? 0
        lastTime = time
        updateTarget(at: time)
        if elapsed > 0 {
            current = approach(current, target, elapsed: elapsed)
        }
        current = clamped(current)
        return pixelRect(current)
    }

    // MARK: - Composition

    private mutating func updateTarget(at time: Double) {
        let members = tracks.filter { time - $0.firstSeen >= parameters.joinDelay && time - $0.lastSeen <= parameters.forgetDelay }
        let wanted: Composition
        if members.isEmpty {
            if let last = lastSubjectTime, time - last < parameters.holdTime {
                return
            }
            wanted = Self.fullComposition(source: source, output: output)
        } else {
            lastSubjectTime = time
            wanted = composition(around: members)
        }
        if !isClose(wanted, target) {
            target = clamped(wanted)
        }
    }

    private func composition(around members: [Track]) -> Composition {
        let width = Double(source.width)
        let height = Double(source.height)
        let group = members.dropFirst().reduce(members[0].body) { $0.union($1.body) }
        let box = (x: group.minX * width, y: group.minY * height, width: group.width * width, height: group.height * height)

        let full = Self.fullComposition(source: source, output: output)
        var cropHeight = max(box.height / parameters.subjectHeightShare, box.width / parameters.subjectWidthShare / aspect)
        cropHeight = min(max(cropHeight, full.height / parameters.maximumZoom), full.height)
        let cropWidth = cropHeight * aspect

        var centerX = box.x + box.width / 2
        let single = members.count == 1 ? members[0] : nil
        if let facing = single?.facing, abs(facing) > parameters.facingDeadZone {
            let strength = min(1, (abs(facing) - parameters.facingDeadZone) / (1 - parameters.facingDeadZone))
            centerX += (facing > 0 ? 1 : -1) * strength * parameters.lookRoom * cropWidth
        }
        // Keep the people inside the crop when the look room would push them out.
        centerX = min(max(centerX, box.x + box.width - cropWidth / 2), box.x + cropWidth / 2)

        let eyeY: Double
        if let face = single?.face {
            eyeY = (face.minY + face.height * 0.42) * height
        } else {
            eyeY = box.y + box.height * 0.15
        }
        var top = eyeY - parameters.eyeLine * cropHeight
        top = min(top, box.y)
        return Composition(centerX: centerX, centerY: top + cropHeight / 2, height: cropHeight)
    }

    private func isClose(_ a: Composition, _ b: Composition) -> Bool {
        let tolerance = parameters.settleShare * b.height
        return abs(a.centerX - b.centerX) < tolerance * aspect
            && abs(a.centerY - b.centerY) < tolerance
            && abs(a.height - b.height) < tolerance
    }

    private func approach(_ from: Composition, _ to: Composition, elapsed: Double) -> Composition {
        // An exponential approach never arrives. Each step moves at least the minimum speed and the
        // last step lands on the target, so a settled crop stops changing.
        let least = parameters.minimumSpeed * from.height * elapsed
        func step(_ from: Double, _ to: Double, time constant: Double, limit: Double) -> Double {
            let distance = to - from
            var move = distance * (1 - exp(-elapsed / constant))
            if abs(move) < least { move = distance > 0 ? least : -least }
            move = min(max(move, -limit), limit)
            return abs(move) >= abs(distance) ? to : from + move
        }
        let panLimit = parameters.maximumPanSpeed * from.height * aspect * elapsed
        let zoomLimit = parameters.maximumZoomSpeed * from.height * elapsed
        return Composition(
            centerX: step(from.centerX, to.centerX, time: parameters.panTime, limit: panLimit),
            centerY: step(from.centerY, to.centerY, time: parameters.panTime, limit: panLimit),
            height: step(from.height, to.height, time: parameters.zoomTime, limit: zoomLimit)
        )
    }

    // MARK: - Geometry

    /// The largest crop of the output's aspect ratio, centered in the picture.
    private static func fullComposition(source: PixelSize, output: PixelSize) -> Composition {
        let width = Double(source.width)
        let height = Double(source.height)
        let aspect = Double(output.width) / Double(output.height)
        let cropHeight = width / height > aspect ? height : width / aspect
        return Composition(centerX: width / 2, centerY: height / 2, height: cropHeight)
    }

    private func clamped(_ composition: Composition) -> Composition {
        let width = Double(source.width)
        let height = Double(source.height)
        let full = Self.fullComposition(source: source, output: output)
        let cropHeight = min(max(composition.height, full.height / parameters.maximumZoom), full.height)
        let cropWidth = cropHeight * aspect
        return Composition(
            centerX: min(max(composition.centerX, cropWidth / 2), width - cropWidth / 2),
            centerY: min(max(composition.centerY, cropHeight / 2), height - cropHeight / 2),
            height: cropHeight
        )
    }

    private func pixelRect(_ composition: Composition) -> PixelRect {
        let cropHeight = max(1, Int(composition.height.rounded()))
        let cropWidth = min(source.width, max(1, Int((composition.height * aspect).rounded())))
        let x = min(max(0, Int((composition.centerX - Double(cropWidth) / 2).rounded())), source.width - cropWidth)
        let y = min(max(0, Int((composition.centerY - Double(cropHeight) / 2).rounded())), source.height - min(cropHeight, source.height))
        return PixelRect(x: x, y: y, width: cropWidth, height: min(cropHeight, source.height))
    }
}
