import Foundation
import LumixProtocol

/// The device's answer to one transaction: its response container and the data it sent, if any.
public struct PTPExchange: Sendable, Equatable {
    public let response: PTPResponse
    public let dataIn: Data

    public init(response: PTPResponse, dataIn: Data = Data()) {
        self.response = response
        self.dataIn = dataIn
    }
}

/// A failure below the PTP layer: the transaction never produced a usable response.
public enum TransportError: Error, Equatable, Sendable {
    /// No response arrived within the transaction's time limit.
    case timedOut
    /// The device is gone or the session is not open.
    case disconnected
    /// The response container could not be decoded.
    case malformedResponse(ProtocolError)
    /// The underlying framework reported an error; the text is its description.
    case failed(String)
}

/// Carries PTP transactions to one camera.
///
/// Implementations own the session with the device; `execute` sends one command container,
/// the host-to-device data when there is any, and returns the response and the device-to-host data.
public protocol PTPTransport: AnyObject, Sendable {
    func openSession() async throws(TransportError)
    func closeSession() async
    func execute(_ command: PTPCommand, dataOut: Data?, timeout: Duration) async throws(TransportError) -> PTPExchange
}
