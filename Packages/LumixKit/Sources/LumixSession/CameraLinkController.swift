import Foundation
import LumixProtocol
import Observation

/// Delays of the link.
public struct LinkTiming: Sendable, Equatable {
    /// Wait before trying a camera again after a failure.
    public var retryDelay: Duration
    /// Minimum spacing between live-view frame requests.
    public var frameInterval: Duration

    public init(retryDelay: Duration, frameInterval: Duration) {
        self.retryDelay = retryDelay
        self.frameInterval = frameInterval
    }

    public static let standard = LinkTiming(retryDelay: .seconds(5), frameInterval: .nanoseconds(1_000_000_000 / 30))
}

/// Frame counts of the current live-view run, for diagnostics.
public struct FrameStatistics: Sendable, Equatable {
    public var frames = 0
    public var busyReplies = 0
    public var lastExtraction: LiveViewJPEG.Extraction?

    public init() {}
}

/// What the user interface shows about the link.
public struct LinkStatus: Sendable, Equatable {
    public var phase: LinkPhase = .searching
    public var cameraName: String?
    public var liveView: LiveViewConfiguration?
    public var statistics = FrameStatistics()
    public var lastError: String?

    public init() {}
}

/// Executes the link reducer's effects against real camera sessions.
@MainActor
@Observable
public final class CameraLinkController {
    public private(set) var status = LinkStatus()

    @ObservationIgnored private var state = LinkState()
    @ObservationIgnored private var endpoints: [CameraID: any CameraEndpoint] = [:]
    @ObservationIgnored private var lanes: [UInt64: SessionLane] = [:]
    @ObservationIgnored private var cameraTails: [CameraID: Task<Void, Never>] = [:]
    @ObservationIgnored private var pump: (generation: UInt64, token: PumpToken)?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var pendingEvents: [LinkEvent] = []
    @ObservationIgnored private var isProcessing = false

    @ObservationIgnored private let timing: LinkTiming
    @ObservationIgnored private let policy: SessionPolicy
    @ObservationIgnored private let frameSink: @Sendable (LiveViewJPEG) -> Void
    @ObservationIgnored private let log = LumixLog.logger(category: "link")

    /// Returns the size the user chose for a camera model, or `nil` for the default choice.
    @ObservationIgnored public var preferredSize: (String) -> LiveViewSize? = { _ in nil }

    public init(timing: LinkTiming = .standard, policy: SessionPolicy = .standard, frameSink: @escaping @Sendable (LiveViewJPEG) -> Void) {
        self.timing = timing
        self.policy = policy
        self.frameSink = frameSink
    }

    public func handle(_ event: DiscoveryEvent) {
        switch event {
        case .appeared(let endpoint):
            endpoints[endpoint.id] = endpoint
            send(.cameraAppeared(endpoint.id))
        case .disappeared(let id):
            send(.cameraDisappeared(id))
            endpoints[id] = nil
        }
    }

    public func setClientsActive(_ active: Bool) {
        send(.clientsChanged(active: active))
    }

    /// Restarts live view so a changed size preference takes effect.
    public func restartLiveView() {
        guard state.clientsActive else { return }
        send(.clientsChanged(active: false))
        send(.clientsChanged(active: true))
    }

    // MARK: - Event processing

    private func send(_ event: LinkEvent) {
        pendingEvents.append(event)
        guard !isProcessing else { return }
        isProcessing = true
        while !pendingEvents.isEmpty {
            let next = pendingEvents.removeFirst()
            for effect in LinkReducer.reduce(&state, next) {
                perform(effect)
            }
        }
        reconcilePump()
        publishStatus()
        isProcessing = false
    }

    private func perform(_ effect: LinkEffect) {
        switch effect {
        case .openSession(let id, let generation):
            open(id, generation: generation)
        case .startLiveView(let generation):
            startLiveView(generation: generation)
        case .stopLiveView(let generation):
            stopPump()
            lanes[generation]?.enqueue { [weak self] session in
                do throws(SessionError) {
                    try await session.stopLiveView()
                } catch {
                    await self?.report(error, generation: generation)
                }
            }
        case .closeSession(let generation):
            stopPump()
            guard let lane = lanes.removeValue(forKey: generation) else { return }
            lane.enqueue { session in await session.close() }
            cameraTails[lane.camera] = lane.tail
            status.liveView = nil
        case .scheduleRetry(let generation):
            retryTask?.cancel()
            let delay = timing.retryDelay
            retryTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
                self?.send(.retryTimerFired(generation: generation))
            }
        }
    }

    private func open(_ id: CameraID, generation: UInt64) {
        guard let endpoint = endpoints[id] else {
            pendingEvents.append(.sessionFailed(generation: generation))
            return
        }
        let session = CameraSession(transport: endpoint.makeTransport(), policy: policy)
        let lane = SessionLane(generation: generation, camera: id, modelName: endpoint.modelName, session: session, after: cameraTails[id])
        lanes[generation] = lane
        status.statistics = FrameStatistics()
        lane.enqueue { [weak self] session in
            do throws(SessionError) {
                try await session.open()
                await self?.send(.sessionOpened(generation: generation))
            } catch {
                await self?.report(error, generation: generation, as: .sessionFailed(generation: generation))
            }
        }
    }

    private func startLiveView(generation: UInt64) {
        guard let lane = lanes[generation] else { return }
        let preference = preferredSize(lane.modelName)
        lane.enqueue { [weak self] session in
            do throws(SessionError) {
                let configuration = try await session.configureLiveView(preferring: preference)
                try await session.startLiveView()
                await self?.liveViewDidStart(configuration, generation: generation)
            } catch {
                await self?.report(error, generation: generation)
            }
        }
    }

    private func liveViewDidStart(_ configuration: LiveViewConfiguration, generation: UInt64) {
        guard generation == state.generation else { return }
        status.liveView = configuration
        send(.liveViewStarted(generation: generation))
    }

    private func report(_ error: SessionError, generation: UInt64, as event: LinkEvent? = nil) {
        log.error("Session \(generation) failed: \(String(describing: error), privacy: .public)")
        if generation == state.generation {
            status.lastError = String(describing: error)
        }
        send(event ?? .communicationFailed(generation: generation))
    }

    // MARK: - Frame pump

    /// Runs the frame pump exactly while the link is streaming.
    private func reconcilePump() {
        if case .streaming = state.phase, let lane = lanes[state.generation] {
            guard pump?.generation != lane.generation else { return }
            stopPump()
            startPump(on: lane)
        } else {
            stopPump()
        }
    }

    private func startPump(on lane: SessionLane) {
        let token = PumpToken()
        let generation = lane.generation
        let interval = timing.frameInterval
        let sink = frameSink
        pump = (generation, token)
        lane.enqueue { [weak self] session in
            let clock = ContinuousClock()
            var statistics = FrameStatistics()
            var lastPublished = clock.now
            while !token.isCancelled {
                let started = clock.now
                do throws(SessionError) {
                    switch try await session.fetchFrame() {
                    case .jpeg(let jpeg):
                        statistics.frames += 1
                        statistics.lastExtraction = jpeg.extraction
                        sink(jpeg)
                    case .busy:
                        statistics.busyReplies += 1
                    }
                } catch {
                    if !token.isCancelled {
                        await self?.report(error, generation: generation)
                    }
                    return
                }
                if clock.now - lastPublished >= .seconds(1) {
                    lastPublished = clock.now
                    let snapshot = statistics
                    await self?.publish(snapshot, generation: generation)
                }
                try? await clock.sleep(until: started + interval)
            }
        }
    }

    private func stopPump() {
        pump?.token.cancel()
        pump = nil
    }

    private func publish(_ statistics: FrameStatistics, generation: UInt64) {
        guard generation == state.generation else { return }
        status.statistics = statistics
    }

    private func publishStatus() {
        status.phase = state.phase
        status.cameraName = state.phase.camera.flatMap { endpoints[$0]?.modelName }
        if case .searching = state.phase {
            status.liveView = nil
        }
    }
}
