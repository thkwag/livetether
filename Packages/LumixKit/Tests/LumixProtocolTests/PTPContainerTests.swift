import Foundation
import Testing
@testable import LumixProtocol

@Suite("PTP containers")
struct PTPContainerTests {
    @Test("Vendor open-session command has the expected byte layout")
    func vendorOpenSessionBytes() throws {
        let command = try PTPCommand(operation: PanasonicOperation.openSession, transactionID: 1, parameters: [0x0001_0001])
        #expect(command.encodedContainer() == Data(hex: "10000000 0100 0291 01000000 01000100"))
    }

    @Test("Command containers round-trip and carry 12 + 4n bytes")
    func commandRoundTrip() throws {
        try forEachSeed { seed, generator in
            let count = Int.random(in: 0...PTPCommand.maximumParameterCount, using: &generator)
            let parameters = (0..<count).map { _ in UInt32.random(in: .min ... .max, using: &generator) }
            let command = try PTPCommand(
                operation: PTPOperationCode(rawValue: .random(in: .min ... .max, using: &generator)),
                transactionID: .random(in: .min ... .max, using: &generator),
                parameters: parameters
            )
            let container = command.encodedContainer()
            #expect(container.count == 12 + 4 * count, "seed \(seed)")
            #expect(try PTPCommand(container: container) == command, "seed \(seed)")
        }
    }

    @Test("A command refuses a sixth parameter")
    func commandParameterLimit() {
        #expect(throws: ProtocolError.tooManyParameters(6)) {
            try PTPCommand(operation: .openSession, transactionID: 0, parameters: [1, 2, 3, 4, 5, 6])
        }
    }

    @Test("Response containers round-trip for every parameter count")
    func responseRoundTrip() throws {
        try forEachSeed { seed, generator in
            let count = Int.random(in: 0...5, using: &generator)
            let response = PTPResponse(
                code: PTPResponseCode(rawValue: .random(in: .min ... .max, using: &generator)),
                transactionID: .random(in: .min ... .max, using: &generator),
                parameters: (0..<count).map { _ in UInt32.random(in: .min ... .max, using: &generator) }
            )
            let decoded = try PTPResponse(container: response.encodedContainer())
            #expect(decoded == response, "seed \(seed)")
        }
    }

    @Test("A response is accepted only between 12 and 32 bytes", arguments: [0, 11, 12, 31, 32, 33, 36])
    func responseLengthBounds(length: Int) {
        var bytes = PTPResponse(code: .ok, transactionID: 7).encodedContainer()
        bytes.append(Data(repeating: 0, count: max(0, length - bytes.count)))
        let container = bytes.prefix(length)
        if (12...32).contains(length) {
            #expect(throws: Never.self) { try PTPResponse(container: Data(container)) }
        } else {
            #expect(throws: ProtocolError.containerLengthOutOfRange(length)) { try PTPResponse(container: Data(container)) }
        }
    }

    @Test("A response with a type other than 3 is refused", arguments: [UInt16(1), 2, 4, 0xFFFF])
    func responseType(type: UInt16) {
        var container = PTPResponse(code: .ok, transactionID: 7).encodedContainer()
        container[4] = UInt8(truncatingIfNeeded: type)
        container[5] = UInt8(truncatingIfNeeded: type >> 8)
        #expect(throws: ProtocolError.unexpectedContainerType(type)) { try PTPResponse(container: container) }
    }

    @Test("Response parameters are counted from the byte count, not the length field")
    func responseParameterCountFromBytes() throws {
        var container = PTPResponse(code: .ok, transactionID: 9, parameters: [0xAABB_CCDD, 0x1122_3344]).encodedContainer()
        container.replaceSubrange(0..<4, with: [0xFF, 0xFF, 0xFF, 0xFF])
        let response = try PTPResponse(container: container)
        #expect(response.parameters == [0xAABB_CCDD, 0x1122_3344])
        #expect(response.code == .ok)
        #expect(response.transactionID == 9)
    }

    @Test("Response codes print their name and value")
    func responseCodeDescription() {
        #expect(PTPResponseCode.deviceBusy.description == "DeviceBusy (0x2019)")
        #expect(PTPResponseCode(rawValue: 0x2999).description == "0x2999")
    }
}
