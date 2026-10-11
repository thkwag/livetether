import Foundation
import LumixProtocol

/// Time limits and retry counts for one camera session.
public struct SessionPolicy: Sendable, Equatable {
    public var commandTimeout: Duration
    public var frameTimeout: Duration
    public var busyRetryDelay: Duration
    public var busyRetryLimit: Int

    public init(commandTimeout: Duration, frameTimeout: Duration, busyRetryDelay: Duration, busyRetryLimit: Int) {
        self.commandTimeout = commandTimeout
        self.frameTimeout = frameTimeout
        self.busyRetryDelay = busyRetryDelay
        self.busyRetryLimit = busyRetryLimit
    }

    public static let standard = SessionPolicy(
        commandTimeout: .seconds(30),
        frameTimeout: .seconds(2),
        busyRetryDelay: .milliseconds(100),
        busyRetryLimit: 3
    )
}

/// A failure of a camera session operation.
public enum SessionError: Error, Equatable, Sendable {
    case notOpen
    /// The task running the operation was cancelled.
    case cancelled
    case transport(TransportError)
    case unexpectedResponse(operation: PTPOperationCode, code: PTPResponseCode)
    case malformedData(ProtocolError)
    /// The camera offers no live-view size at the required frame rate.
    case noUsableLiveViewSize
}

/// The live-view sizes the camera offered, the one requested, and the one it reports in effect.
public struct LiveViewConfiguration: Sendable, Equatable {
    public let available: [LiveViewSize]
    public let requested: LiveViewSize
    public let current: LiveViewSize
}

/// The outcome of one live-view frame request.
public enum FrameResult: Sendable, Equatable {
    case jpeg(LiveViewJPEG)
    /// The camera answered Device Busy; no new frame is available yet.
    case busy
}

/// Runs the Panasonic live-view command sequence over one transport.
///
/// Every transaction gets the next transaction ID, starting at 1 after each session open.
/// A control command answered Device Busy is retried after a delay up to the policy's limit;
/// a frame request answered Device Busy is reported as `.busy`. A transaction that times out is
/// sent once more after the session is closed and reopened and the live-view state restored;
/// a second time-out is reported to the caller.
public actor CameraSession {
    private enum Kind {
        case control
        case frame
    }

    private let transport: any PTPTransport
    private let policy: SessionPolicy
    private let sleep: @Sendable (Duration) async throws -> Void
    private let log = LumixLog.logger(category: "session")

    private var isOpen = false
    private var nextTransactionID: UInt32 = 1
    /// How far the device's transaction IDs run from the ones sent; only a change is logged.
    private var transactionOffset: UInt32 = 0
    private var configuredSize: LiveViewSize?
    private var liveViewActive = false

    public init(
        transport: any PTPTransport,
        policy: SessionPolicy = .standard,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.transport = transport
        self.policy = policy
        self.sleep = sleep
    }

    /// Opens the transport session, then the Panasonic vendor session.
    public func open() async throws(SessionError) {
        try await openTransportAndVendorSession()
    }

    /// Ends the vendor session and the transport session; failures are logged, not thrown.
    public func close() async {
        if isOpen {
            do {
                _ = try await perform(.panasonicCloseSession(), kind: .control, mayReopen: false)
            } catch {
                log.notice("Vendor close-session failed: \(String(describing: error), privacy: .public)")
            }
        }
        await transport.closeSession()
        isOpen = false
        liveViewActive = false
    }

    /// Reads the offered sizes, sets the preferred one (or the automatic choice), and reads back the size in effect.
    public func configureLiveView(preferring preference: LiveViewSize?) async throws(SessionError) -> LiveViewConfiguration {
        let listReply = try await performExpectingOK(.liveViewSizeList())
        let available = try decoded { () throws(ProtocolError) in try LiveViewSize.decodeList(from: listReply.dataIn) }
        let matched = preference.flatMap { wanted in
            available.first { $0.width == wanted.width && $0.height == wanted.height && $0.framesPerSecond == wanted.framesPerSecond }
        }
        guard let requested = matched ?? LiveViewSize.preferred(in: available) else {
            throw .noUsableLiveViewSize
        }
        _ = try await performExpectingOK(.setLiveViewSize(requested))
        configuredSize = requested
        let currentReply = try await performExpectingOK(.liveViewCurrentSize())
        let current = try decoded { () throws(ProtocolError) in try LiveViewSize.decodeCurrent(from: currentReply.dataIn) }
        if current.width != requested.width || current.height != requested.height {
            log.notice("Camera reports \(current.description, privacy: .public) after \(requested.description, privacy: .public) was set")
        }
        return LiveViewConfiguration(available: available, requested: requested, current: current)
    }

    public func startLiveView() async throws(SessionError) {
        _ = try await performExpectingOK(.liveView(start: true))
        liveViewActive = true
    }

    public func stopLiveView() async throws(SessionError) {
        liveViewActive = false
        _ = try await performExpectingOK(.liveView(start: false))
    }

    public func fetchFrame() async throws(SessionError) -> FrameResult {
        let reply = try await perform(.liveViewImage(), kind: .frame, mayReopen: true)
        switch reply.response.code {
        case .ok:
            return .jpeg(try decoded { () throws(ProtocolError) in try LiveViewFrameParser.extractJPEG(from: reply.dataIn) })
        case .deviceBusy:
            return .busy
        default:
            throw .unexpectedResponse(operation: PanasonicOperation.liveViewImage, code: reply.response.code)
        }
    }

    // MARK: - Transactions

    private func openTransportAndVendorSession() async throws(SessionError) {
        do {
            try await transport.openSession()
        } catch {
            throw .transport(error)
        }
        isOpen = true
        nextTransactionID = 1
        transactionOffset = 0
        let reply = try await perform(.panasonicOpenSession(), kind: .control, mayReopen: false)
        guard reply.response.code == .ok || reply.response.code == .sessionAlreadyOpen else {
            throw .unexpectedResponse(operation: PanasonicOperation.openSession, code: reply.response.code)
        }
    }

    private func performExpectingOK(_ request: PTPRequest) async throws(SessionError) -> PTPExchange {
        let reply = try await perform(request, kind: .control, mayReopen: true)
        guard reply.response.code == .ok else {
            throw .unexpectedResponse(operation: request.operation, code: reply.response.code)
        }
        return reply
    }

    private func perform(_ request: PTPRequest, kind: Kind, mayReopen: Bool) async throws(SessionError) -> PTPExchange {
        guard isOpen else { throw .notOpen }
        var busyRetries = 0
        var reopened = false
        while true {
            let reply: PTPExchange
            do {
                reply = try await send(request, timeout: kind == .frame ? policy.frameTimeout : policy.commandTimeout)
            } catch .timedOut where mayReopen && !reopened {
                log.notice("\(request.description, privacy: .public) timed out; reopening the session")
                reopened = true
                try await reopenSession()
                continue
            } catch {
                throw .transport(error)
            }
            if reply.response.code == .deviceBusy, kind == .control, busyRetries < policy.busyRetryLimit {
                busyRetries += 1
                do {
                    try await sleep(policy.busyRetryDelay)
                } catch is CancellationError {
                    throw .cancelled
                } catch {
                    throw .transport(.failed(String(describing: error)))
                }
                continue
            }
            return reply
        }
    }

    private func send(_ request: PTPRequest, timeout: Duration) async throws(TransportError) -> PTPExchange {
        let transactionID = takeTransactionID()
        let command = PTPCommand(request, transactionID: transactionID)
        let reply = try await transport.execute(command, dataOut: request.dataOut, timeout: timeout)
        let offset = reply.response.transactionID &- transactionID
        if offset != transactionOffset {
            transactionOffset = offset
            log.notice("\(request.description, privacy: .public) answered with transaction \(reply.response.transactionID) instead of \(transactionID); replies at the same offset are not logged")
        }
        return reply
    }

    private func takeTransactionID() -> UInt32 {
        let value = nextTransactionID
        nextTransactionID &+= 1
        if nextTransactionID == 0 || nextTransactionID == .max {
            nextTransactionID = 1
        }
        return value
    }

    /// Closes and reopens the transport and vendor sessions, then restores the live-view size and state.
    private func reopenSession() async throws(SessionError) {
        let restoreLiveView = liveViewActive
        await transport.closeSession()
        isOpen = false
        liveViewActive = false
        try await openTransportAndVendorSession()
        if let size = configuredSize {
            _ = try await performWithoutReopen(.setLiveViewSize(size))
        }
        if restoreLiveView {
            _ = try await performWithoutReopen(.liveView(start: true))
            liveViewActive = true
        }
    }

    private func performWithoutReopen(_ request: PTPRequest) async throws(SessionError) -> PTPExchange {
        let reply = try await perform(request, kind: .control, mayReopen: false)
        guard reply.response.code == .ok else {
            throw .unexpectedResponse(operation: request.operation, code: reply.response.code)
        }
        return reply
    }

    private func decoded<Value>(_ body: () throws(ProtocolError) -> Value) throws(SessionError) -> Value {
        do {
            return try body()
        } catch {
            throw .malformedData(error)
        }
    }
}
