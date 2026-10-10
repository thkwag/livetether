import Foundation

/// A PTP command container, the block handed to the transport for one transaction.
///
/// Layout (little-endian): `u32 length | u16 type (1) | u16 operation | u32 transactionID | u32 parameter[0...5]`.
public struct PTPCommand: Hashable, Sendable {
    public static let headerLength = 12
    public static let maximumParameterCount = 5

    public let operation: PTPOperationCode
    public let transactionID: UInt32
    public let parameters: [UInt32]

    public init(operation: PTPOperationCode, transactionID: UInt32, parameters: [UInt32] = []) throws(ProtocolError) {
        guard parameters.count <= Self.maximumParameterCount else {
            throw .tooManyParameters(parameters.count)
        }
        self.operation = operation
        self.transactionID = transactionID
        self.parameters = parameters
    }

    /// Decodes a command container; the length field must match the bytes received.
    public init(container: Data) throws(ProtocolError) {
        let maximumLength = Self.headerLength + 4 * Self.maximumParameterCount
        guard container.count >= Self.headerLength, container.count <= maximumLength,
              (container.count - Self.headerLength) % 4 == 0 else {
            throw .containerLengthOutOfRange(container.count)
        }
        var reader = ByteReader(container)
        let length = try reader.readUInt32()
        guard Int(length) == container.count else {
            throw .containerLengthMismatch(declared: length, actual: container.count)
        }
        let type = try reader.readUInt16()
        guard type == PTPContainerType.command.rawValue else {
            throw .unexpectedContainerType(type)
        }
        let operation = PTPOperationCode(rawValue: try reader.readUInt16())
        let transactionID = try reader.readUInt32()
        var parameters: [UInt32] = []
        while reader.remaining > 0 {
            parameters.append(try reader.readUInt32())
        }
        try self.init(operation: operation, transactionID: transactionID, parameters: parameters)
    }

    public func encodedContainer() -> Data {
        var writer = ByteWriter()
        writer.write(UInt32(Self.headerLength + 4 * parameters.count))
        writer.write(PTPContainerType.command.rawValue)
        writer.write(operation.rawValue)
        writer.write(transactionID)
        for parameter in parameters {
            writer.write(parameter)
        }
        return writer.data
    }
}

/// A PTP response container, returned by the device after every transaction.
///
/// The container must be 12 to 32 bytes long
/// with type 3; the code sits at `+0x6`, the transaction ID at `+0x8`, and the parameter count is
/// `(byte count − 12) / 4`. The container's own length field is not consulted.
public struct PTPResponse: Hashable, Sendable {
    public static let minimumContainerLength = 12
    public static let maximumContainerLength = 32

    public let code: PTPResponseCode
    public let transactionID: UInt32
    public let parameters: [UInt32]

    public init(code: PTPResponseCode, transactionID: UInt32, parameters: [UInt32] = []) {
        self.code = code
        self.transactionID = transactionID
        self.parameters = parameters
    }

    public init(container: Data) throws(ProtocolError) {
        guard container.count >= Self.minimumContainerLength,
              container.count <= Self.maximumContainerLength else {
            throw .containerLengthOutOfRange(container.count)
        }
        var reader = ByteReader(container)
        try reader.skip(4)
        let type = try reader.readUInt16()
        guard type == PTPContainerType.response.rawValue else {
            throw .unexpectedContainerType(type)
        }
        let code = PTPResponseCode(rawValue: try reader.readUInt16())
        let transactionID = try reader.readUInt32()
        let parameterCount = (container.count - Self.minimumContainerLength) / 4
        var parameters: [UInt32] = []
        for _ in 0..<parameterCount {
            parameters.append(try reader.readUInt32())
        }
        self.init(code: code, transactionID: transactionID, parameters: parameters)
    }

    public func encodedContainer() -> Data {
        var writer = ByteWriter()
        writer.write(UInt32(Self.minimumContainerLength + 4 * parameters.count))
        writer.write(PTPContainerType.response.rawValue)
        writer.write(code.rawValue)
        writer.write(transactionID)
        for parameter in parameters {
            writer.write(parameter)
        }
        return writer.data
    }
}
