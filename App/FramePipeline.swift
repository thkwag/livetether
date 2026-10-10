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
final class FramePipeline: Sendable {
    static let reconnectInterval: Duration = .seconds(1)

    private struct State {
        var lastConnectAttempt: ContinuousClock.Instant?
        var lastFailureLog: ContinuousClock.Instant?
    }

    private let decoder = JPEGDecoder()
    private let sink = SinkStreamClient()
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let log = LumixLog.logger(category: "pipeline")

    func deliver(_ jpeg: LiveViewJPEG) {
        let picture: CVPixelBuffer
        do {
            picture = try decoder.decode(jpeg.data)
        } catch {
            report("Decoding a live-view image failed: \(error)")
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
