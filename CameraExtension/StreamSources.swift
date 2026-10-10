import CoreMedia
import CoreMediaIO
import Foundation
import LumixProtocol
import LumixVirtualCamera

/// The stream video-call applications read.
final class SourceStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let streamFormats: [CMIOExtensionStreamFormat]
    private let output: OutputGenerator
    private let log = LumixLog.logger(category: "extension-source")

    private(set) var activeFormatIndex = VirtualCameraFormats.defaultIndex

    init(formats: [CMIOExtensionStreamFormat], output: OutputGenerator) {
        streamFormats = formats
        self.output = output
        super.init()
        stream = CMIOExtensionStream(
            localizedName: VirtualCameraIdentity.sourceStreamName,
            streamID: VirtualCameraIdentity.sourceStreamID,
            direction: .source,
            clockType: .hostTime,
            source: self
        )
    }

    var formats: [CMIOExtensionStreamFormat] { streamFormats }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = activeFormatIndex
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = CMTime(value: 1, timescale: CMTimeScale(VirtualCameraFormats.framesPerSecond))
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        guard let index = streamProperties.activeFormatIndex else { return }
        guard streamFormats.indices.contains(index) else {
            log.error("Refused format index \(index)")
            throw CocoaError(.featureUnsupported)
        }
        activeFormatIndex = index
        output.setActiveFormatIndex(index)
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        true
    }

    func startStream() throws {
        output.sourceStarted()
    }

    func stopStream() throws {
        output.sourceStopped()
    }
}

/// The stream the app writes camera pictures into.
final class SinkStreamSource: NSObject, CMIOExtensionStreamSource {
    /// Buffers the app may queue ahead of the extension; the app drops a picture when the queue is full.
    static let queueSize = 2

    private(set) var stream: CMIOExtensionStream!
    private let streamFormats: [CMIOExtensionStreamFormat]
    private let output: OutputGenerator
    private var pendingClient: CMIOExtensionClient?

    init(formats: [CMIOExtensionStreamFormat], output: OutputGenerator) {
        streamFormats = formats
        self.output = output
        super.init()
        stream = CMIOExtensionStream(
            localizedName: VirtualCameraIdentity.sinkStreamName,
            streamID: VirtualCameraIdentity.sinkStreamID,
            direction: .sink,
            clockType: .hostTime,
            source: self
        )
    }

    var formats: [CMIOExtensionStreamFormat] { streamFormats }

    var activeFormatIndex: Int { 0 }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize,
         .streamSinkBuffersRequiredForStartup, .streamSinkBufferUnderrunCount, .streamSinkEndOfData]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = CMTime(value: 1, timescale: CMTimeScale(VirtualCameraFormats.framesPerSecond))
        }
        if properties.contains(.streamSinkBufferQueueSize) {
            streamProperties.sinkBufferQueueSize = Self.queueSize
        }
        if properties.contains(.streamSinkBuffersRequiredForStartup) {
            streamProperties.sinkBuffersRequiredForStartup = 1
        }
        if properties.contains(.streamSinkBufferUnderrunCount) {
            streamProperties.sinkBufferUnderrunCount = 0
        }
        if properties.contains(.streamSinkEndOfData) {
            streamProperties.sinkEndOfData = 0
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        // The sink accepts pictures of any size; its format is not settable.
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        pendingClient = client
        return true
    }

    func startStream() throws {
        guard let client = pendingClient else { throw CocoaError(.featureUnsupported) }
        output.sinkStarted(client: client)
    }

    func stopStream() throws {
        pendingClient = nil
        output.sinkStopped()
    }
}
