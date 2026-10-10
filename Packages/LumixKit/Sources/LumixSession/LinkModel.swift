import Foundation

/// Identifies one attached camera for as long as it stays attached.
public struct CameraID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// Why the link is waiting before it tries the camera again.
public enum RetryReason: Equatable, Sendable {
    /// The session could not be opened; another application may hold the camera.
    case openFailed
    /// A transaction failed or timed out after the session was open.
    case communicationFailed
}

/// Where the link to the camera stands.
public enum LinkPhase: Equatable, Sendable {
    /// No eligible camera is attached.
    case searching
    case opening(CameraID)
    /// The session is open and live view is off.
    case ready(CameraID)
    case startingLiveView(CameraID)
    case streaming(CameraID)
    case waitingToRetry(CameraID, RetryReason)

    public var camera: CameraID? {
        switch self {
        case .searching:
            return nil
        case .opening(let id), .ready(let id), .startingLiveView(let id), .streaming(let id), .waitingToRetry(let id, _):
            return id
        }
    }
}

/// The link state the reducer owns.
public struct LinkState: Equatable, Sendable {
    public var phase: LinkPhase = .searching
    /// Eligible cameras in the order they appeared.
    public var cameras: [CameraID] = []
    /// Whether any application is reading the virtual camera's video stream.
    public var clientsActive = false
    /// Increases with every session the link opens; results of earlier sessions are ignored.
    public var generation: UInt64 = 0

    public init() {}
}

/// Something that happened to the link. Results of asynchronous work carry the generation they belong to.
public enum LinkEvent: Equatable, Sendable {
    case cameraAppeared(CameraID)
    case cameraDisappeared(CameraID)
    case sessionOpened(generation: UInt64)
    case sessionFailed(generation: UInt64)
    case liveViewStarted(generation: UInt64)
    case communicationFailed(generation: UInt64)
    case clientsChanged(active: Bool)
    case retryTimerFired(generation: UInt64)
}

/// Work the executor performs for the link.
public enum LinkEffect: Equatable, Sendable {
    case openSession(CameraID, generation: UInt64)
    case startLiveView(generation: UInt64)
    case stopLiveView(generation: UInt64)
    case closeSession(generation: UInt64)
    /// Wait the retry delay, then deliver `.retryTimerFired` with this generation.
    case scheduleRetry(generation: UInt64)
}

/// The connection lifecycle as a pure transition function.
public enum LinkReducer {
    public static func reduce(_ state: inout LinkState, _ event: LinkEvent) -> [LinkEffect] {
        switch event {
        case .cameraAppeared(let id):
            guard !state.cameras.contains(id) else { return [] }
            state.cameras.append(id)
            guard state.phase == .searching else { return [] }
            return open(id, &state)

        case .cameraDisappeared(let id):
            guard let index = state.cameras.firstIndex(of: id) else { return [] }
            state.cameras.remove(at: index)
            guard state.phase.camera == id else { return [] }
            var effects: [LinkEffect] = []
            if case .waitingToRetry = state.phase {} else {
                effects.append(.closeSession(generation: state.generation))
            }
            return effects + openNextOrSearch(&state)

        case .sessionOpened(let generation):
            guard generation == state.generation, case .opening(let id) = state.phase else { return [] }
            state.phase = .ready(id)
            return state.clientsActive ? startLiveView(id, &state) : []

        case .sessionFailed(let generation):
            guard generation == state.generation, case .opening(let id) = state.phase else { return [] }
            return waitToRetry(id, .openFailed, &state)

        case .liveViewStarted(let generation):
            guard generation == state.generation, case .startingLiveView(let id) = state.phase else { return [] }
            if state.clientsActive {
                state.phase = .streaming(id)
                return []
            }
            state.phase = .ready(id)
            return [.stopLiveView(generation: generation)]

        case .communicationFailed(let generation):
            guard generation == state.generation else { return [] }
            switch state.phase {
            case .opening(let id), .ready(let id), .startingLiveView(let id), .streaming(let id):
                return waitToRetry(id, .communicationFailed, &state)
            case .searching, .waitingToRetry:
                return []
            }

        case .clientsChanged(let active):
            guard state.clientsActive != active else { return [] }
            state.clientsActive = active
            switch state.phase {
            case .ready(let id) where active:
                return startLiveView(id, &state)
            case .streaming(let id) where !active:
                state.phase = .ready(id)
                return [.stopLiveView(generation: state.generation)]
            default:
                return []
            }

        case .retryTimerFired(let generation):
            guard generation == state.generation, case .waitingToRetry(let id, _) = state.phase else { return [] }
            if state.cameras.contains(id) {
                return open(id, &state)
            }
            return openNextOrSearch(&state)
        }
    }

    private static func open(_ id: CameraID, _ state: inout LinkState) -> [LinkEffect] {
        state.generation += 1
        state.phase = .opening(id)
        return [.openSession(id, generation: state.generation)]
    }

    private static func openNextOrSearch(_ state: inout LinkState) -> [LinkEffect] {
        guard let next = state.cameras.first else {
            state.phase = .searching
            return []
        }
        return open(next, &state)
    }

    private static func startLiveView(_ id: CameraID, _ state: inout LinkState) -> [LinkEffect] {
        state.phase = .startingLiveView(id)
        return [.startLiveView(generation: state.generation)]
    }

    private static func waitToRetry(_ id: CameraID, _ reason: RetryReason, _ state: inout LinkState) -> [LinkEffect] {
        state.phase = .waitingToRetry(id, reason)
        return [.closeSession(generation: state.generation), .scheduleRetry(generation: state.generation)]
    }
}
