import Foundation
import LumixProtocol
import os
import Testing
@testable import LumixSession

@Suite("Camera link controller")
@MainActor
struct CameraLinkControllerTests {
    /// Longest wait for an expected event; reaching it means the event never happened.
    static let hangGuard: Duration = .seconds(10)

    let camera = FakeCamera()
    let frames = FrameCollector()

    func makeController() -> CameraLinkController {
        let collector = frames
        return CameraLinkController(
            timing: LinkTiming(retryDelay: .milliseconds(20), frameInterval: .milliseconds(1)),
            policy: SessionPolicy(commandTimeout: .seconds(30), frameTimeout: .seconds(2), busyRetryDelay: .zero, busyRetryLimit: 3),
            frameSink: { collector.append($0) }
        )
    }

    func endpoint(_ name: String = "first") -> FakeEndpoint {
        FakeEndpoint(id: CameraID(name), modelName: "DC-GH6", camera: camera)
    }

    @Test("Frames flow only while a client reads the stream")
    func framesFollowClients() async throws {
        let controller = makeController()
        controller.handle(.appeared(endpoint()))
        try await waitUntil("session opened") { controller.status.phase == .ready(CameraID("first")) }
        #expect(frames.count == 0)

        controller.setClientsActive(true)
        try await waitUntil("three frames delivered") { frames.count >= 3 }
        #expect(controller.status.phase == .streaming(CameraID("first")))
        #expect(controller.status.liveView?.current == FakeCamera.gc9Sizes[2])
        #expect(controller.status.cameraName == "DC-GH6")

        controller.setClientsActive(false)
        try await waitUntil("live view stopped") {
            camera.commands.last.map { $0.operation == 0x9412 && $0.parameters == [0x0D00_0011] } ?? false
        }
        let delivered = frames.count
        try await Task.sleep(for: .milliseconds(50))
        #expect(frames.count == delivered, "frames kept arriving after live view stopped")
    }

    @Test("Removing the camera closes its session and returns to searching")
    func removalCloses() async throws {
        let controller = makeController()
        controller.handle(.appeared(endpoint()))
        controller.setClientsActive(true)
        try await waitUntil("streaming") { frames.count >= 1 }
        controller.handle(.disappeared(CameraID("first")))
        #expect(controller.status.phase == .searching)
        try await waitUntil("session closed") { camera.entries.last == .closeSession }
        #expect(camera.commands.last?.operation == 0x9103)
    }

    @Test("A communication failure waits, reopens, and resumes the stream")
    func recoversAfterFailure() async throws {
        let controller = makeController()
        controller.handle(.appeared(endpoint()))
        controller.setClientsActive(true)
        try await waitUntil("streaming") { frames.count >= 1 }
        camera.inject([.disconnected], for: PanasonicOperation.liveViewImage)
        try await waitUntil("waiting to retry") {
            if case .waitingToRetry = controller.status.phase { return true }
            return false
        }
        let before = frames.count
        try await waitUntil("stream resumed") { frames.count > before + 2 }
        #expect(controller.status.phase == .streaming(CameraID("first")))
        #expect(camera.entries.filter { $0 == .openSession }.count == 2)
    }

    @Test("A camera that refuses the session is retried")
    func retriesRefusedSession() async throws {
        camera.failOpenSession(with: .failed("held by another application"))
        let controller = makeController()
        controller.handle(.appeared(endpoint()))
        try await waitUntil("two attempts") { camera.entries.filter { $0 == .openSession }.count >= 2 }
        camera.failOpenSession(with: nil)
        try await waitUntil("session opened") { controller.status.phase == .ready(CameraID("first")) }
    }

    /// Polls `condition` on the main actor until it holds; fails naming `event` when the hang guard runs out.
    func waitUntil(_ event: String, _ condition: @MainActor () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + Self.hangGuard
        while !condition() {
            if clock.now >= deadline {
                Issue.record("Never happened within \(Self.hangGuard): \(event)")
                throw WaitError.neverHappened(event)
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    enum WaitError: Error {
        case neverHappened(String)
    }
}

/// Collects delivered frames across threads.
final class FrameCollector: Sendable {
    private let frames = OSAllocatedUnfairLock<[LiveViewJPEG]>(initialState: [])

    func append(_ frame: LiveViewJPEG) {
        frames.withLock { $0.append(frame) }
    }

    var count: Int { frames.withLock { $0.count } }
}
