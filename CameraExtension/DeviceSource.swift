import CoreMedia
import CoreMediaIO
import Foundation
import IOKit.audio
import LumixVideo
import LumixVirtualCamera

/// The virtual camera device: a source stream applications read and a sink stream the app writes pictures into.
final class DeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var source: SourceStreamSource!
    private var sink: SinkStreamSource!
    private let output = OutputGenerator()

    override init() {
        super.init()
        device = CMIOExtensionDevice(
            localizedName: VirtualCameraIdentity.deviceName,
            deviceID: VirtualCameraIdentity.deviceID,
            legacyDeviceID: nil,
            source: self
        )
        let formats = VirtualCameraFormats.all.map(Self.streamFormat)
        source = SourceStreamSource(formats: formats, output: output)
        sink = SinkStreamSource(formats: formats, output: output)
        output.sourceStream = source.stream
        output.sinkStream = sink.stream
        do {
            try device.addStream(source.stream)
            try device.addStream(sink.stream)
        } catch {
            fatalError("Failed to add the virtual camera streams: \(error.localizedDescription)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            deviceProperties.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            deviceProperties.model = VirtualCameraIdentity.modelName
        }
        return deviceProperties
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {
        // The device has no settable properties.
    }

    private static func streamFormat(_ format: StreamFormat) -> CMIOExtensionStreamFormat {
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: Int32(format.size.width),
            height: Int32(format.size.height),
            extensions: nil,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else {
            fatalError("Failed to describe the \(format) stream format: \(status)")
        }
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(format.framesPerSecond))
        return CMIOExtensionStreamFormat(formatDescription: description, maxFrameDuration: frameDuration, minFrameDuration: frameDuration, validFrameDurations: nil)
    }
}
