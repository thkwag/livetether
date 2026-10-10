import Foundation
@preconcurrency import ImageCaptureCore
import LumixProtocol
import LumixSession
import os

/// PTP transport over ImageCaptureCore's pass-through to one camera.
///
/// ImageCaptureCore requests cannot be cancelled, so a time-out resolves the waiting caller and the
/// late completion, if it ever arrives, is dropped. Requests are issued on the main thread, where
/// ImageCaptureCore delivers its delegate callbacks.
final class ImageCaptureTransport: PTPTransport, @unchecked Sendable {
    // `ICCameraDevice` is not Sendable; it is only touched on the main thread (see `onMain`).
    private let camera: ICCameraDevice
    private let log = LumixLog.logger(category: "imagecapture")

    init(camera: ICCameraDevice) {
        self.camera = camera
    }

    func openSession() async throws(TransportError) {
        let result: Result<Void, TransportError> = await withCheckedContinuation { continuation in
            let gate = ResumeOnce(continuation)
            onMain { camera in
                if camera.hasOpenSession {
                    gate.resume(.success(()))
                    return
                }
                camera.requestOpenSession(options: nil) { error in
                    gate.resume(error.map { .failure(Self.transportError($0)) } ?? .success(()))
                }
            }
        }
        try result.get()
    }

    func closeSession() async {
        let result: Result<Void, TransportError> = await withCheckedContinuation { continuation in
            let gate = ResumeOnce(continuation)
            onMain { camera in
                guard camera.hasOpenSession else {
                    gate.resume(.success(()))
                    return
                }
                camera.requestCloseSession(options: nil) { error in
                    gate.resume(error.map { .failure(Self.transportError($0)) } ?? .success(()))
                }
            }
        }
        if case .failure(let error) = result {
            log.notice("Close session failed: \(String(describing: error), privacy: .public)")
        }
    }

    func execute(_ command: PTPCommand, dataOut: Data?, timeout: Duration) async throws(TransportError) -> PTPExchange {
        let container = command.encodedContainer()
        let result: Result<PTPExchange, TransportError> = await withCheckedContinuation { continuation in
            let gate = ResumeOnce(continuation)
            onMain { camera in
                camera.requestSendPTPCommand(container, outData: dataOut) { dataIn, responseContainer, error in
                    if let error {
                        gate.resume(.failure(Self.transportError(error)))
                        return
                    }
                    do throws(ProtocolError) {
                        let response = try PTPResponse(container: responseContainer)
                        gate.resume(.success(PTPExchange(response: response, dataIn: dataIn)))
                    } catch {
                        gate.resume(.failure(.malformedResponse(error)))
                    }
                }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout.timeInterval) {
                gate.resume(.failure(.timedOut))
            }
        }
        return try result.get()
    }

    private func onMain(_ body: @escaping @MainActor (ICCameraDevice) -> Void) {
        let camera = self.camera
        DispatchQueue.main.async {
            MainActor.assumeIsolated { body(camera) }
        }
    }

    private static func transportError(_ error: any Error) -> TransportError {
        let nsError = error as NSError
        return .failed("\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)")
    }
}

/// Resumes a continuation once; later results are dropped.
final class ResumeOnce<Value: Sendable>: Sendable {
    private let continuation: OSAllocatedUnfairLock<CheckedContinuation<Result<Value, TransportError>, Never>?>

    init(_ continuation: CheckedContinuation<Result<Value, TransportError>, Never>) {
        self.continuation = OSAllocatedUnfairLock(initialState: continuation)
    }

    func resume(_ result: Result<Value, TransportError>) {
        let pending = continuation.withLock { stored -> CheckedContinuation<Result<Value, TransportError>, Never>? in
            defer { stored = nil }
            return stored
        }
        pending?.resume(returning: result)
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
