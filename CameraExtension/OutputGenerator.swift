import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import LumixProtocol
import LumixVideo
import LumixVirtualCamera
import os

/// Produces the virtual camera's video: the latest picture from the sink stream placed in the active
/// format, or the standby frame for the app's link status.
///
/// All mutable state is confined to `queue`; CoreMediaIO callbacks hop onto it.
final class OutputGenerator: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.github.thkwag.lumixwebcam.extension.output", qos: .userInteractive)
    private let log = LumixLog.logger(category: "extension-output")
    private let renderer = StandbyRenderer()
    private let pools = PixelBufferPools()
    private let sourceActive: DarwinStateChannel?
    private let linkStatus: DarwinStateChannel?

    private var linkObservation: DarwinObservation?
    private var statusWord = StatusWord(encoded: 0)
    private var timer: DispatchSourceTimer?
    private var sourceClients = 0
    private var activeFormatIndex = VirtualCameraFormats.defaultIndex
    private var sinkClient: CMIOExtensionClient?
    private var sinkGeneration = 0
    private var latest: (buffer: CVPixelBuffer, receivedAt: Double)?

    weak var sourceStream: CMIOExtensionStream?
    weak var sinkStream: CMIOExtensionStream?

    init() {
        sourceActive = Self.channel(VirtualCameraIdentity.sourceActiveNotification, log: log)
        linkStatus = Self.channel(VirtualCameraIdentity.linkStatusNotification, log: log)
        sourceActive?.publish(0)
        queue.async { [self] in
            guard let linkStatus else { return }
            statusWord = StatusWord(encoded: linkStatus.currentValue())
            do {
                linkObservation = try linkStatus.observe(on: queue) { [weak self] value in
                    self?.statusWord = StatusWord(encoded: value)
                }
            } catch {
                log.error("Observing the link status failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func setActiveFormatIndex(_ index: Int) {
        queue.async { [self] in activeFormatIndex = index }
    }

    // MARK: - Source stream

    func sourceStarted() {
        queue.async { [self] in
            sourceClients += 1
            guard sourceClients == 1 else { return }
            startTimer()
            sourceActive?.publish(1)
        }
    }

    func sourceStopped() {
        queue.async { [self] in
            sourceClients = max(0, sourceClients - 1)
            guard sourceClients == 0 else { return }
            timer?.cancel()
            timer = nil
            sourceActive?.publish(0)
        }
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(VirtualCameraFormats.framesPerSecond), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.emitFrame() }
        timer.resume()
        self.timer = timer
    }

    private func emitFrame() {
        guard let stream = sourceStream else { return }
        let format = VirtualCameraFormats.all[activeFormatIndex]
        let now = Self.hostSeconds()
        let decision = OutputPolicy.decide(
            lastFrameAge: latest.map { now - $0.receivedAt },
            indicator: statusWord.effectiveIndicator(at: Date())
        )
        do {
            let frame: CVPixelBuffer
            switch decision {
            case .cameraFrame:
                guard let picture = latest?.buffer else { return }
                frame = try pools.makeBuffer(size: format.size)
                try FrameCompositor.compose(picture, into: frame)
            case .standby(let message):
                frame = try renderer.frame(for: message, size: format.size)
            }
            try send(frame, on: stream)
        } catch {
            log.error("Producing a frame failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func send(_ frame: CVPixelBuffer, on stream: CMIOExtensionStream) throws(VideoError) {
        var format: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: frame, formatDescriptionOut: &format)
        guard formatStatus == noErr, let format else { throw .bufferCreationFailed(formatStatus) }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(VirtualCameraFormats.framesPerSecond)),
            presentationTimeStamp: now,
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: frame,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        )
        guard sampleStatus == noErr, let sample else { throw .bufferCreationFailed(sampleStatus) }
        stream.send(sample, discontinuity: [], hostTimeInNanoseconds: UInt64(now.seconds * Double(NSEC_PER_SEC)))
    }

    // MARK: - Sink stream

    func sinkStarted(client: CMIOExtensionClient) {
        let box = ClientBox(client: client)
        queue.async { [self] in
            sinkClient = box.client
            sinkGeneration += 1
            consume(generation: sinkGeneration)
        }
    }

    func sinkStopped() {
        queue.async { [self] in
            sinkClient = nil
            sinkGeneration += 1
            latest = nil
        }
    }

    /// Takes the next picture the app sent; runs again after every buffer while the sink is open.
    private func consume(generation: Int) {
        guard generation == sinkGeneration, let client = sinkClient, let stream = sinkStream else { return }
        stream.consumeSampleBuffer(from: client) { [weak self] sample, sequenceNumber, _, _, error in
            let box = SampleBox(sample: sample, error: error)
            guard let self else { return }
            self.queue.async {
                self.received(box, sequenceNumber: sequenceNumber, generation: generation)
            }
        }
    }

    private func received(_ box: SampleBox, sequenceNumber: UInt64, generation: Int) {
        guard generation == sinkGeneration, let stream = sinkStream else { return }
        guard let sample = box.sample, let picture = CMSampleBufferGetImageBuffer(sample) else {
            if let error = box.error {
                log.debug("Sink consume returned no buffer: \(String(describing: error), privacy: .public)")
            }
            queue.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in
                self?.consume(generation: generation)
            }
            return
        }
        latest = (picture, Self.hostSeconds())
        let output = CMIOExtensionScheduledOutput(
            sequenceNumber: sequenceNumber,
            hostTimeInNanoseconds: UInt64(Self.hostSeconds() * Double(NSEC_PER_SEC))
        )
        stream.notifyScheduledOutputChanged(output)
        consume(generation: generation)
    }

    // MARK: - Helpers

    private static func hostSeconds() -> Double {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }

    private static func channel(_ name: String, log: Logger) -> DarwinStateChannel? {
        do {
            return try DarwinStateChannel(name: name)
        } catch {
            log.error("Darwin channel \(name, privacy: .public) unavailable: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

/// Carries a CoreMediaIO client across the hop onto the output queue, where it is used exclusively.
private struct ClientBox: @unchecked Sendable {
    let client: CMIOExtensionClient
}

/// Carries a consumed sample buffer across the hop onto the output queue.
private struct SampleBox: @unchecked Sendable {
    let sample: CMSampleBuffer?
    let error: (any Error)?
}
