import Foundation

/// Panasonic vendor operation codes used by the LUMIX live-view path.
public enum PanasonicOperation {
    public static let openSession = PTPOperationCode(rawValue: 0x9102)
    public static let closeSession = PTPOperationCode(rawValue: 0x9103)
    public static let liveView = PTPOperationCode(rawValue: 0x9412)
    public static let getLiveViewParameters = PTPOperationCode(rawValue: 0x9414)
    public static let setLiveViewParameters = PTPOperationCode(rawValue: 0x9415)
    public static let liveViewImage = PTPOperationCode(rawValue: 0x9706)
}

/// Parameter values and property codes carried by the Panasonic live-view operations.
public enum PanasonicValue {
    /// Parameter of the vendor open-session operation.
    public static let sessionStorageID: UInt32 = 0x0001_0001
    public static let liveViewStart: UInt32 = 0x0D00_0010
    public static let liveViewStop: UInt32 = 0x0D00_0011
    /// Property code of the live-view size currently in effect.
    public static let liveViewCurrentSize: UInt32 = 0x0D80_0011
    /// Property code of the list of live-view sizes the camera offers.
    public static let liveViewSizeList: UInt32 = 0x0D80_0012
}

/// One transaction to perform, before the session assigns its transaction ID.
public struct PTPRequest: Hashable, Sendable, CustomStringConvertible {
    public let operation: PTPOperationCode
    public let parameters: [UInt32]
    public let dataPhase: PTPDataPhase
    /// The data sent to the device; present exactly when `dataPhase` is `.hostToDevice`.
    public let dataOut: Data?

    public init(operation: PTPOperationCode, parameters: [UInt32] = [], dataPhase: PTPDataPhase, dataOut: Data? = nil) {
        precondition((dataPhase == .hostToDevice) == (dataOut != nil), "dataOut must accompany a host-to-device data phase")
        self.operation = operation
        self.parameters = parameters
        self.dataPhase = dataPhase
        self.dataOut = dataOut
    }

    public var description: String {
        let parameterText = parameters.map { String(format: "0x%08X", $0) }.joined(separator: ", ")
        return "\(operation)(\(parameterText))"
    }

    public static func panasonicOpenSession() -> PTPRequest {
        PTPRequest(operation: PanasonicOperation.openSession, parameters: [PanasonicValue.sessionStorageID], dataPhase: .none)
    }

    public static func panasonicCloseSession() -> PTPRequest {
        PTPRequest(operation: PanasonicOperation.closeSession, dataPhase: .none)
    }

    public static func liveView(start: Bool) -> PTPRequest {
        let value = start ? PanasonicValue.liveViewStart : PanasonicValue.liveViewStop
        return PTPRequest(operation: PanasonicOperation.liveView, parameters: [value], dataPhase: .none)
    }

    public static func liveViewSizeList() -> PTPRequest {
        PTPRequest(operation: PanasonicOperation.getLiveViewParameters, parameters: [PanasonicValue.liveViewSizeList], dataPhase: .deviceToHost)
    }

    public static func liveViewCurrentSize() -> PTPRequest {
        PTPRequest(operation: PanasonicOperation.getLiveViewParameters, parameters: [PanasonicValue.liveViewCurrentSize], dataPhase: .deviceToHost)
    }

    public static func setLiveViewSize(_ size: LiveViewSize) -> PTPRequest {
        PTPRequest(
            operation: PanasonicOperation.setLiveViewParameters,
            parameters: [PanasonicValue.liveViewCurrentSize],
            dataPhase: .hostToDevice,
            dataOut: size.setPropertyBlock()
        )
    }

    public static func liveViewImage() -> PTPRequest {
        PTPRequest(operation: PanasonicOperation.liveViewImage, dataPhase: .deviceToHost)
    }
}
