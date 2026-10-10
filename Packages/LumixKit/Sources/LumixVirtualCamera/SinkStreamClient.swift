import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import LumixProtocol

/// A failure to reach or feed the virtual camera's sink stream.
public enum SinkError: Error, Equatable, Sendable {
    case deviceNotFound
    case sinkStreamNotFound
    case queueUnavailable(OSStatus)
    case startFailed(OSStatus)
    case notConnected
    case queueFull
    case sampleBufferCreationFailed(OSStatus)
}

/// Feeds pictures to the camera extension through its sink stream.
///
/// The app is a CoreMediaIO client of its own virtual camera: it finds the device by UID, starts the
/// sink stream and appends sample buffers to the stream's queue, which the extension consumes.
public final class SinkStreamClient: @unchecked Sendable {
    // Mutable state is guarded by `lock`; CoreMediaIO calls are made while holding it.
    private struct Connection {
        let device: CMIOObjectID
        let stream: CMIOStreamID
        let queue: CMSimpleQueue
    }

    private let lock = NSLock()
    private var connection: Connection?
    private let log = LumixLog.logger(category: "sink")

    public init() {}

    public var isConnected: Bool { lock.withLock { connection != nil } }

    public func connect() throws(SinkError) {
        lock.lock()
        defer { lock.unlock() }
        guard connection == nil else { return }
        guard let device = CMIOProperties.devices().first(where: { CMIOProperties.deviceUID($0) == VirtualCameraIdentity.deviceUID }) else {
            throw .deviceNotFound
        }
        guard let stream = CMIOProperties.streams(of: device).first(where: { CMIOProperties.isOutputStream($0) }) else {
            throw .sinkStreamNotFound
        }
        var queue: Unmanaged<CMSimpleQueue>?
        let copyStatus = CMIOStreamCopyBufferQueue(stream, { _, _, _ in }, nil, &queue)
        guard copyStatus == noErr, let queue else {
            throw .queueUnavailable(copyStatus)
        }
        let startStatus = CMIODeviceStartStream(device, stream)
        guard startStatus == noErr else {
            throw .startFailed(startStatus)
        }
        connection = Connection(device: device, stream: stream, queue: queue.takeRetainedValue())
        log.info("Sink stream \(stream) of device \(device) started")
    }

    public func disconnect() {
        lock.withLock {
            guard let current = connection else { return }
            let status = CMIODeviceStopStream(current.device, current.stream)
            if status != noErr {
                log.notice("Stopping the sink stream returned \(status)")
            }
            connection = nil
        }
    }

    /// Appends one picture, stamped with the current host time; refuses when the queue is full.
    public func send(_ pixelBuffer: CVPixelBuffer) throws(SinkError) {
        lock.lock()
        defer { lock.unlock() }
        guard let current = connection else { throw .notConnected }
        guard CMSimpleQueueGetCount(current.queue) < CMSimpleQueueGetCapacity(current.queue) else {
            throw .queueFull
        }
        var format: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
        guard formatStatus == noErr, let format else {
            throw .sampleBufferCreationFailed(formatStatus)
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(VirtualCameraFormats.framesPerSecond)),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        )
        guard sampleStatus == noErr, let sample else {
            throw .sampleBufferCreationFailed(sampleStatus)
        }
        // The queue takes ownership of the retained sample buffer; the consumer releases it.
        let enqueueStatus = CMSimpleQueueEnqueue(current.queue, element: Unmanaged.passRetained(sample).toOpaque())
        if enqueueStatus != noErr {
            Unmanaged.passUnretained(sample).release()
            throw .queueFull
        }
    }
}

/// Typed reads of CoreMediaIO object properties.
enum CMIOProperties {
    static func address(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
    }

    static func devices() -> [CMIOObjectID] {
        objectList(of: CMIOObjectID(kCMIOObjectSystemObject), selector: kCMIOHardwarePropertyDevices)
    }

    static func streams(of device: CMIOObjectID) -> [CMIOStreamID] {
        objectList(of: device, selector: kCMIODevicePropertyStreams)
    }

    static func deviceUID(_ device: CMIOObjectID) -> String? {
        var address = address(kCMIODevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var used: UInt32 = 0
        let status = CMIOObjectGetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Unmanaged<CFString>?>.size), &used, &uid)
        guard status == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    /// A CoreMediaIO output stream carries data from the host to the device, which is a sink.
    static func isOutputStream(_ stream: CMIOStreamID) -> Bool {
        var address = address(kCMIOStreamPropertyDirection)
        var direction: UInt32 = 1
        var used: UInt32 = 0
        let status = CMIOObjectGetPropertyData(stream, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &direction)
        return status == noErr && direction == 0
    }

    private static func objectList(of object: CMIOObjectID, selector: Int) -> [CMIOObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, &objects) == noErr else { return [] }
        return Array(objects.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }
}
