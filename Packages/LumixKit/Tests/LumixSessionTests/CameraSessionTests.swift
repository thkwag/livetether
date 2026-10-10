import Foundation
import LumixProtocol
import Testing
@testable import LumixSession

@Suite("Camera session")
struct CameraSessionTests {
    let camera = FakeCamera()

    func makeSession(sleeps: SleepRecorder = SleepRecorder()) -> CameraSession {
        CameraSession(transport: camera, policy: .standard, sleep: { duration in sleeps.record(duration) })
    }

    @Test("Opening sends the vendor open-session with transaction 1 after the transport session")
    func openSequence() async throws {
        try await makeSession().open()
        #expect(camera.entries == [
            .openSession,
            .command(operation: 0x9102, transactionID: 1, parameters: [0x0001_0001], dataOut: nil),
        ])
    }

    @Test("An already-open vendor session counts as opened (D7)")
    func sessionAlreadyOpenIsAccepted() async throws {
        camera.inject([.response(.sessionAlreadyOpen)], for: PanasonicOperation.openSession)
        try await makeSession().open()
    }

    @Test("Any other vendor open-session answer is refused")
    func vendorOpenFailure() async {
        camera.inject([.response(.operationNotSupported)], for: PanasonicOperation.openSession)
        await #expect(throws: SessionError.unexpectedResponse(operation: PanasonicOperation.openSession, code: .operationNotSupported)) {
            try await makeSession().open()
        }
    }

    @Test("A transport that cannot open is reported as such")
    func transportOpenFailure() async {
        camera.failOpenSession(with: .disconnected)
        await #expect(throws: SessionError.transport(.disconnected)) { try await makeSession().open() }
    }

    @Test("Configuring reads the list, sets the automatic choice, and reads back the current size")
    func configureSequence() async throws {
        let session = makeSession()
        try await session.open()
        let configuration = try await session.configureLiveView(preferring: nil)
        let expected = FakeCamera.gc9Sizes[2]
        #expect(configuration.available == FakeCamera.gc9Sizes)
        #expect(configuration.requested == expected)
        #expect(configuration.current == expected)
        let commands = camera.commands.dropFirst()
        #expect(commands.map(\.operation) == [0x9414, 0x9415, 0x9414])
        #expect(commands.map(\.transactionID) == [2, 3, 4])
        #expect(commands.map(\.parameters) == [[0x0D80_0012], [0x0D80_0011], [0x0D80_0011]])
        #expect(Array(commands)[1].dataOut == expected.setPropertyBlock())
    }

    @Test("A preference the camera offers wins; one it does not offer falls back to the automatic choice")
    func preferenceHandling() async throws {
        let session = makeSession()
        try await session.open()
        let offered = FakeCamera.gc9Sizes[1]
        #expect(try await session.configureLiveView(preferring: offered).requested == offered)
        let absent = LiveViewSize(width: 1920, height: 1080, opaqueValue: 0, framesPerSecond: 30)
        #expect(try await session.configureLiveView(preferring: absent).requested == FakeCamera.gc9Sizes[2])
    }

    @Test("A camera without a 30 fps size is refused")
    func noUsableSize() async throws {
        let camera = FakeCamera(sizes: [LiveViewSize(width: 640, height: 480, opaqueValue: 0, framesPerSecond: 60)])
        let session = CameraSession(transport: camera, sleep: { _ in })
        try await session.open()
        await #expect(throws: SessionError.noUsableLiveViewSize) { try await session.configureLiveView(preferring: nil) }
    }

    @Test("A busy control command is retried three times after 100 ms each (D14)")
    func busyControlRetries() async throws {
        let sleeps = SleepRecorder()
        let session = makeSession(sleeps: sleeps)
        try await session.open()
        camera.inject([.busy, .busy, .busy], for: PanasonicOperation.liveView)
        try await session.startLiveView()
        #expect(camera.commands.filter { $0.operation == 0x9412 }.count == 4)
        #expect(sleeps.durations == [.milliseconds(100), .milliseconds(100), .milliseconds(100)])
    }

    @Test("A fourth busy answer to a control command is an error")
    func busyControlLimit() async throws {
        let session = makeSession()
        try await session.open()
        camera.inject([.busy, .busy, .busy, .busy], for: PanasonicOperation.liveView)
        await #expect(throws: SessionError.unexpectedResponse(operation: PanasonicOperation.liveView, code: .deviceBusy)) {
            try await session.startLiveView()
        }
    }

    @Test("A busy frame request is reported without a retry")
    func busyFrame() async throws {
        let session = makeSession()
        try await session.open()
        camera.inject([.busy], for: PanasonicOperation.liveViewImage)
        #expect(try await session.fetchFrame() == .busy)
        #expect(camera.commands.filter { $0.operation == 0x9706 }.count == 1)
    }

    @Test("A frame reply yields the JPEG it carries")
    func frameReply() async throws {
        let session = makeSession()
        try await session.open()
        guard case .jpeg(let jpeg) = try await session.fetchFrame() else {
            Issue.record("expected a JPEG frame")
            return
        }
        #expect(jpeg.data == Data([0xFF, 0xD8, 0x01, 0x00, 0xFF, 0xD9]))
        #expect(jpeg.extraction == .tagged)
    }

    @Test("A timed-out frame request reopens the session, restores live view, and is sent once more (D15)")
    func frameTimeoutReopens() async throws {
        let session = makeSession()
        try await session.open()
        _ = try await session.configureLiveView(preferring: nil)
        try await session.startLiveView()
        let before = camera.entries.count
        camera.inject([.timeout], for: PanasonicOperation.liveViewImage)
        guard case .jpeg = try await session.fetchFrame() else {
            Issue.record("expected a JPEG frame after the reopen")
            return
        }
        let size = FakeCamera.gc9Sizes[2]
        #expect(Array(camera.entries.dropFirst(before)) == [
            .command(operation: 0x9706, transactionID: 6, parameters: [], dataOut: nil),
            .closeSession,
            .openSession,
            .command(operation: 0x9102, transactionID: 1, parameters: [0x0001_0001], dataOut: nil),
            .command(operation: 0x9415, transactionID: 2, parameters: [0x0D80_0011], dataOut: size.setPropertyBlock()),
            .command(operation: 0x9412, transactionID: 3, parameters: [0x0D00_0010], dataOut: nil),
            .command(operation: 0x9706, transactionID: 4, parameters: [], dataOut: nil),
        ])
    }

    @Test("A second time-out after the reopen is reported")
    func secondTimeoutIsReported() async throws {
        let session = makeSession()
        try await session.open()
        camera.inject([.timeout, .timeout], for: PanasonicOperation.liveViewImage)
        await #expect(throws: SessionError.transport(.timedOut)) { try await session.fetchFrame() }
    }

    @Test("Closing ends the vendor session before the transport session")
    func closeSequence() async throws {
        let session = makeSession()
        try await session.open()
        await session.close()
        #expect(Array(camera.entries.suffix(2)) == [
            .command(operation: 0x9103, transactionID: 2, parameters: [], dataOut: nil),
            .closeSession,
        ])
        await #expect(throws: SessionError.notOpen) { try await session.fetchFrame() }
    }
}

/// Records requested sleeps instead of waiting.
final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Duration] = []

    func record(_ duration: Duration) {
        lock.withLock { recorded.append(duration) }
    }

    var durations: [Duration] { lock.withLock { recorded } }
}
