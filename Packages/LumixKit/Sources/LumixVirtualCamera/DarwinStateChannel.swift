import Dispatch
import Foundation
import notify

/// A failure to register for a Darwin notification name.
public enum DarwinChannelError: Error, Equatable, Sendable {
    case registrationFailed(name: String, status: UInt32)
}

/// A 64-bit value shared between processes through a Darwin notification name.
///
/// Darwin notifications cross the sandbox boundary between the app and the camera extension,
/// which runs as a different user; each side publishes its state and observes the other's.
public final class DarwinStateChannel: @unchecked Sendable {
    // The token is written once in `init` and released in `deinit`; notify(3) calls on it are thread-safe.
    public let name: String
    private let token: Int32

    public init(name: String) throws(DarwinChannelError) {
        var token: Int32 = 0
        let status = notify_register_check(name, &token)
        guard status == NOTIFY_STATUS_OK else {
            throw .registrationFailed(name: name, status: status)
        }
        self.name = name
        self.token = token
    }

    deinit {
        notify_cancel(token)
    }

    /// Stores `value` as the name's state and notifies observers.
    public func publish(_ value: UInt64) {
        notify_set_state(token, value)
        notify_post(name)
    }

    public func currentValue() -> UInt64 {
        var value: UInt64 = 0
        notify_get_state(token, &value)
        return value
    }

    /// Calls `handler` on `queue` with the state each time the name is posted, until the observation is released.
    public func observe(on queue: DispatchQueue, _ handler: @escaping @Sendable (UInt64) -> Void) throws(DarwinChannelError) -> DarwinObservation {
        var token: Int32 = 0
        let status = notify_register_dispatch(name, &token, queue) { token in
            var value: UInt64 = 0
            notify_get_state(token, &value)
            handler(value)
        }
        guard status == NOTIFY_STATUS_OK else {
            throw .registrationFailed(name: name, status: status)
        }
        return DarwinObservation(token: token)
    }
}

/// Keeps a Darwin notification observation alive; releasing it cancels the observation.
public final class DarwinObservation: Sendable {
    private let token: Int32

    init(token: Int32) {
        self.token = token
    }

    deinit {
        notify_cancel(token)
    }
}
