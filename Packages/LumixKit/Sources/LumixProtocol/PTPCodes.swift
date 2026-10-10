import Foundation

/// A PTP operation code (the 16-bit command identifier).
public struct PTPOperationCode: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let openSession = PTPOperationCode(rawValue: 0x1002)
    public static let closeSession = PTPOperationCode(rawValue: 0x1003)

    public var description: String { String(format: "0x%04X", rawValue) }
}

/// A PTP response code returned by the device at the end of every transaction.
public struct PTPResponseCode: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let ok = PTPResponseCode(rawValue: 0x2001)
    public static let generalError = PTPResponseCode(rawValue: 0x2002)
    public static let sessionNotOpen = PTPResponseCode(rawValue: 0x2003)
    public static let invalidTransactionID = PTPResponseCode(rawValue: 0x2004)
    public static let operationNotSupported = PTPResponseCode(rawValue: 0x2005)
    public static let parameterNotSupported = PTPResponseCode(rawValue: 0x2006)
    public static let deviceBusy = PTPResponseCode(rawValue: 0x2019)
    public static let sessionAlreadyOpen = PTPResponseCode(rawValue: 0x201E)

    private static let names: [UInt16: String] = [
        0x2001: "OK",
        0x2002: "GeneralError",
        0x2003: "SessionNotOpen",
        0x2004: "InvalidTransactionID",
        0x2005: "OperationNotSupported",
        0x2006: "ParameterNotSupported",
        0x2019: "DeviceBusy",
        0x201E: "SessionAlreadyOpen",
    ]

    public var description: String {
        let hex = String(format: "0x%04X", rawValue)
        guard let name = Self.names[rawValue] else { return hex }
        return "\(name) (\(hex))"
    }
}

/// The direction of a transaction's data phase.
public enum PTPDataPhase: Sendable, Hashable {
    case none
    case deviceToHost
    case hostToDevice
}

/// The container type field of a PTP USB container.
public enum PTPContainerType: UInt16, Sendable {
    case command = 1
    case data = 2
    case response = 3
    case event = 4
}
