import CoreVideo
import Foundation
import LumixProtocol
import LumixVideo
import LumixVirtualCamera
import os

/// Turns live-view JPEG images into pictures on the camera extension's sink stream.
///
/// Runs on the frame pump's task, off the main thread. The sink is connected on the first picture
/// and reconnected at most once a second after a failure; a picture that finds the sink queue full
/// is dropped, because a newer one follows within a frame.
///
/// With automatic framing on, every picture is cropped around the people in it and scaled to the
/// size the virtual camera's reader uses. People are looked for a few times a second on a
/// separate queue, so the detection never holds up a picture.
final class FramePipeline: Sendable {
    static let reconnectInterval: Duration = .seconds(1)
    /// Seconds between two detections of people.
    static let detectionInterval = 0.2

    private struct State {
        var lastConnectAttempt: ContinuousClock.Instant?
        var lastFailureLog: ContinuousClock.Instant?
    }

    private struct Framing {
        var enabled = false
        var output: PixelSize?
        var framer: AutoFramer?
        var detecting = false
        var lastDetection: Double?
    }

    /// A decoded picture handed to the detection queue. The pipeline never writes to a picture
    /// after decoding it, so reading it on another queue is safe.
    private struct PictureBox: @unchecked Sendable {
        let picture: CVPixelBuffer
    }

    private struct EyeContact {
        var corrector: EyeContactCorrector?
        var enabled = false
        /// Rises to 1 over a third of a second after the correction is switched on, and falls back to 0.
        var level = 0.0
        var lastTime: Double?
    }

    /// Seconds the eye contact correction takes to fade in or out.
    static let eyeContactFade = 0.3

    private let eyeContact = OSAllocatedUnfairLock(initialState: EyeContact())
    private let landmarks = FaceLandmarkFinder()
    private let decoder = JPEGDecoder()
    private let sink = SinkStreamClient()
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let framing = OSAllocatedUnfairLock(initialState: Framing())
    private let detector = PersonDetector()
    private let detectionQueue = DispatchQueue(label: "com.github.thkwag.lumixwebcam.framing", qos: .userInitiated)
    private let pools = PixelBufferPools()
    private let started = ContinuousClock.now
    private let log = LumixLog.logger(category: "pipeline")

    /// The eye contact correction, or nil when this build has no gaze model.
    func setEyeContact(_ corrector: EyeContactCorrector?, enabled: Bool) {
        eyeContact.withLock { state in
            state.corrector = corrector
            state.enabled = enabled && corrector != nil
        }
    }

    func setAutoFraming(_ enabled: Bool) {
        framing.withLock { state in
            state.enabled = enabled
            state.framer = nil
        }
    }

    /// The size of the picture the virtual camera's reader receives.
    func setOutputSize(_ size: PixelSize) {
        framing.withLock { state in
            guard state.output != size else { return }
            state.output = size
            state.framer = nil
        }
    }

    func deliver(_ jpeg: LiveViewJPEG) {
        let picture: CVPixelBuffer
        do {
            picture = try framed(try correctedEyes(try decoder.decode(jpeg.data)))
        } catch {
            report("Preparing a live-view image failed: \(error)")
            return
        }
        guard connectIfDue() else { return }
        do {
            try sink.send(picture)
        } catch .queueFull {
            return
        } catch {
            report("Sending a picture to the camera extension failed: \(error)")
        }
    }

    /// The picture with the eyes of faces looking at the camera redirected toward it, fading in and
    /// out when the correction is switched.
    private func correctedEyes(_ picture: CVPixelBuffer) throws(VideoError) -> CVPixelBuffer {
        let elapsed = ContinuousClock.now - started
        let now = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let step = eyeContact.withLock { state -> (EyeContactCorrector, Double)? in
            let interval = state.lastTime.map { min(now - $0, 0.5) } ?? 0
            state.lastTime = now
            let change = interval / Self.eyeContactFade
            state.level = state.enabled ? min(1, state.level + change) : max(0, state.level - change)
            guard state.level > 0, let corrector = state.corrector else { return nil }
            return (corrector, state.level)
        }
        guard let (corrector, level) = step else { return picture }
        for face in try landmarks.faces(in: picture) {
            try corrector.correct(picture, face: face, strength: level * EyeContactCorrector.strength(for: face))
        }
        return picture
    }

    /// The picture as the reader should see it: unchanged without automatic framing, otherwise the
    /// framed crop at the reader's size.
    private func framed(_ picture: CVPixelBuffer) throws(VideoError) -> CVPixelBuffer {
        let elapsed = ContinuousClock.now - started
        let now = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let source = picture.pixelSize
        let plan = framing.withLock { state -> (rect: PixelRect, output: PixelSize, detect: Bool)? in
            guard state.enabled, let output = state.output else { return nil }
            var framer = state.framer.flatMap { $0.source == source ? $0 : nil } ?? AutoFramer(source: source, output: output)
            let rect = framer.crop(at: now)
            state.framer = framer
            let detect = !state.detecting && state.lastDetection.map { now - $0 >= Self.detectionInterval } ?? true
            if detect {
                state.detecting = true
                state.lastDetection = now
            }
            return (rect, output, detect)
        }
        guard let plan else { return picture }
        if plan.detect {
            let box = PictureBox(picture: picture)
            detectionQueue.async { [self] in detectPeople(in: box.picture, at: now) }
        }
        let target = try pools.makeBuffer(size: plan.output)
        try FrameCropper.crop(picture, to: plan.rect, into: target)
        return target
    }

    private func detectPeople(in picture: CVPixelBuffer, at time: Double) {
        let subjects: [FramingSubject]
        do {
            subjects = try detector.detect(in: picture)
        } catch {
            report("Looking for people failed: \(error)")
            subjects = []
        }
        let source = picture.pixelSize
        framing.withLock { state in
            state.detecting = false
            guard state.framer?.source == source else { return }
            state.framer?.observe(subjects, at: time)
        }
    }

    /// Stops the sink stream so the extension stops showing pictures.
    func stop() {
        sink.disconnect()
    }

    private func connectIfDue() -> Bool {
        if sink.isConnected { return true }
        let now = ContinuousClock.now
        let due = state.withLock { state -> Bool in
            if let last = state.lastConnectAttempt, now - last < Self.reconnectInterval {
                return false
            }
            state.lastConnectAttempt = now
            return true
        }
        guard due else { return false }
        do {
            try sink.connect()
            return true
        } catch {
            report("Connecting to the camera extension failed: \(error)")
            return false
        }
    }

    /// Logs a failure at most once a second, so a persistent fault does not flood the log at the frame rate.
    private func report(_ message: String) {
        let now = ContinuousClock.now
        let due = state.withLock { state -> Bool in
            if let last = state.lastFailureLog, now - last < .seconds(1) {
                return false
            }
            state.lastFailureLog = now
            return true
        }
        if due {
            log.error("\(message, privacy: .public)")
        }
    }
}
