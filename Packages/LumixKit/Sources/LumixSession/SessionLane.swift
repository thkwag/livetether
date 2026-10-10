import Foundation
import os

/// Runs the operations of one camera session strictly one after another.
///
/// `CameraSession` is an actor, so two operations sent to it concurrently could interleave at
/// their suspension points (for example a close running in the middle of an open). Every
/// operation the controller performs on a session is therefore appended to its lane and starts
/// only after the previous one finished. A lane for a camera may also start after the last
/// operation of an earlier lane for the same camera, so a new session never opens while the
/// previous one is still closing.
@MainActor
final class SessionLane {
    let generation: UInt64
    let camera: CameraID
    let modelName: String
    let session: CameraSession
    private(set) var tail: Task<Void, Never>?

    init(generation: UInt64, camera: CameraID, modelName: String, session: CameraSession, after predecessor: Task<Void, Never>?) {
        self.generation = generation
        self.camera = camera
        self.modelName = modelName
        self.session = session
        self.tail = predecessor
    }

    func enqueue(_ operation: @escaping @Sendable (CameraSession) async -> Void) {
        let previous = tail
        let session = self.session
        tail = Task.detached {
            await previous?.value
            await operation(session)
        }
    }
}

/// A cancellation flag the frame pump checks between requests.
final class PumpToken: Sendable {
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    var isCancelled: Bool { cancelled.withLock { $0 } }

    func cancel() {
        cancelled.withLock { $0 = true }
    }
}
