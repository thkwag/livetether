import Foundation
import LumixProtocol
import LumixSession
import os

/// A scripted Panasonic camera behind the `PTPTransport` interface, for tests only.
///
/// It answers the live-view operations with blocks in the recorded GC9 layout and can be told to
/// answer Device Busy, time out, or report the device gone for chosen operations.
final class FakeCamera: PTPTransport, @unchecked Sendable {
    enum Entry: Equatable {
        case openSession
        case closeSession
        case command(operation: UInt16, transactionID: UInt32, parameters: [UInt32], dataOut: Data?)
    }

    enum Fault: Equatable {
        case busy
        case timeout
        case disconnected
        case response(PTPResponseCode)
    }

    private struct State {
        var entries: [Entry] = []
        var sizes: [LiveViewSize]
        var current: LiveViewSize
        var faults: [UInt16: [Fault]] = [:]
        var openSessionFailure: TransportError?
        var frameCounter: UInt8 = 0
    }

    private let state: OSAllocatedUnfairLock<State>

    init(sizes: [LiveViewSize] = FakeCamera.gc9Sizes) {
        state = OSAllocatedUnfairLock(initialState: State(sizes: sizes, current: sizes.first ?? FakeCamera.gc9Sizes[0]))
    }

    static let gc9Sizes = [
        LiveViewSize(width: 640, height: 480, opaqueValue: 0x20, framesPerSecond: 30),
        LiveViewSize(width: 960, height: 720, opaqueValue: 0x15E, framesPerSecond: 30),
        LiveViewSize(width: 1280, height: 960, opaqueValue: 0x2BC, framesPerSecond: 30),
    ]

    var entries: [Entry] { state.withLock { $0.entries } }

    var commands: [(operation: UInt16, transactionID: UInt32, parameters: [UInt32], dataOut: Data?)] {
        entries.compactMap {
            if case let .command(operation, transactionID, parameters, dataOut) = $0 {
                return (operation, transactionID, parameters, dataOut)
            }
            return nil
        }
    }

    /// Queues faults the camera produces, in order, the next times `operation` is requested.
    func inject(_ faults: [Fault], for operation: PTPOperationCode) {
        state.withLock { $0.faults[operation.rawValue, default: []].append(contentsOf: faults) }
    }

    func failOpenSession(with error: TransportError?) {
        state.withLock { $0.openSessionFailure = error }
    }

    func openSession() async throws(TransportError) {
        let failure = state.withLock { state -> TransportError? in
            state.entries.append(.openSession)
            return state.openSessionFailure
        }
        if let failure { throw failure }
    }

    func closeSession() async {
        state.withLock { $0.entries.append(.closeSession) }
    }

    func execute(_ command: PTPCommand, dataOut: Data?, timeout: Duration) async throws(TransportError) -> PTPExchange {
        let outcome = state.withLock { state -> Result<PTPExchange, TransportError> in
            state.entries.append(.command(operation: command.operation.rawValue, transactionID: command.transactionID, parameters: command.parameters, dataOut: dataOut))
            if var queued = state.faults[command.operation.rawValue], !queued.isEmpty {
                let fault = queued.removeFirst()
                state.faults[command.operation.rawValue] = queued
                switch fault {
                case .busy:
                    return .success(Self.reply(command, .deviceBusy))
                case .response(let code):
                    return .success(Self.reply(command, code))
                case .timeout:
                    return .failure(.timedOut)
                case .disconnected:
                    return .failure(.disconnected)
                }
            }
            return .success(Self.answer(command, dataOut: dataOut, state: &state))
        }
        return try outcome.get()
    }

    private static func reply(_ command: PTPCommand, _ code: PTPResponseCode, data: Data = Data()) -> PTPExchange {
        PTPExchange(response: PTPResponse(code: code, transactionID: command.transactionID), dataIn: data)
    }

    private static func answer(_ command: PTPCommand, dataOut: Data?, state: inout State) -> PTPExchange {
        switch command.operation {
        case PanasonicOperation.getLiveViewParameters where command.parameters == [PanasonicValue.liveViewSizeList]:
            return reply(command, .ok, data: sizeListBlock(state.sizes))
        case PanasonicOperation.getLiveViewParameters where command.parameters == [PanasonicValue.liveViewCurrentSize]:
            return reply(command, .ok, data: state.current.setPropertyBlock())
        case PanasonicOperation.setLiveViewParameters:
            guard let dataOut, let size = try? LiveViewSize.decodeCurrent(from: dataOut) else {
                return reply(command, .parameterNotSupported)
            }
            state.current = size
            return reply(command, .ok)
        case PanasonicOperation.liveViewImage:
            state.frameCounter &+= 1
            return reply(command, .ok, data: frameBlock(marker: state.frameCounter))
        default:
            return reply(command, .ok)
        }
    }

    static func sizeListBlock(_ sizes: [LiveViewSize]) -> Data {
        var payload = ByteWriter()
        payload.write(UInt16(sizes.count))
        payload.write(UInt16(LiveViewSize.entryLength))
        for size in sizes {
            payload.write(size.height)
            payload.write(size.width)
            payload.write(size.opaqueValue)
            payload.write(size.framesPerSecond)
        }
        var block = ByteWriter()
        block.write(PanasonicValue.liveViewSizeList)
        block.write(UInt32(payload.data.count))
        block.write(payload.data)
        return block.data
    }

    /// A tagged live-view block whose JPEG body carries `marker`, so tests can tell frames apart.
    static func frameBlock(marker: UInt8) -> Data {
        let jpeg = Data([0xFF, 0xD8, marker, 0x00, 0xFF, 0xD9])
        let headerLength = 2 * (TaggedRecords.headerLength + 8)
        var block = ByteWriter()
        for (tag, value) in [(LiveViewFrameTag.jpegOffset, UInt32(headerLength)), (LiveViewFrameTag.jpegSize, UInt32(jpeg.count + 12))] {
            block.write(tag)
            block.write(UInt32(8))
            block.write(UInt32(0))
            block.write(value)
        }
        block.write(jpeg)
        return block.data
    }
}

/// An endpoint that hands out one fake camera.
struct FakeEndpoint: CameraEndpoint {
    let id: CameraID
    let modelName: String
    let camera: FakeCamera

    func makeTransport() -> any PTPTransport { camera }
}
