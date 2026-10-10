import Foundation
import LumixVideo

/// Identifiers and names of the virtual camera, shared by the app and the camera extension.
public enum VirtualCameraIdentity {
    /// The extension's device ID; CoreMediaIO reports its UUID string as the device UID.
    public static let deviceID = UUID(uuidString: "8C037482-01A9-4A23-A72B-AD52E8BFBCE5")!
    public static let sourceStreamID = UUID(uuidString: "C573536A-1488-407C-B379-3F6992A544D6")!
    public static let sinkStreamID = UUID(uuidString: "5256F64F-D6B4-48E1-9853-E18C29D5C279")!

    public static let deviceName = "LiveTether"
    public static let modelName = "LiveTether"
    /// The independent project that provides the virtual camera, not the camera maker.
    public static let manufacturer = "LiveTether Project"
    public static let sourceStreamName = "LiveTether Video"
    public static let sinkStreamName = "LiveTether Input"

    public static var deviceUID: String { deviceID.uuidString }

    /// Prefix of the Darwin notification names the app and the extension exchange state on.
    static let notificationPrefix = "com.github.thkwag.lumixwebcam"
    /// Set by the extension: 1 while any application reads the video stream, else 0.
    public static let sourceActiveNotification = notificationPrefix + ".source-active"
    /// Set by the app: its link status as a `StatusWord`.
    public static let linkStatusNotification = notificationPrefix + ".link-status"
}

/// One output format of the virtual camera.
public struct StreamFormat: Hashable, Sendable, CustomStringConvertible {
    public let size: PixelSize
    public let framesPerSecond: Int

    public init(size: PixelSize, framesPerSecond: Int) {
        self.size = size
        self.framesPerSecond = framesPerSecond
    }

    public var description: String { "\(size)@\(framesPerSecond)" }
}

/// The formats the virtual camera offers.
public enum VirtualCameraFormats {
    public static let framesPerSecond = 30

    public static let all: [StreamFormat] = [
        StreamFormat(size: PixelSize(width: 1920, height: 1080), framesPerSecond: framesPerSecond),
        StreamFormat(size: PixelSize(width: 1280, height: 720), framesPerSecond: framesPerSecond),
        StreamFormat(size: PixelSize(width: 1280, height: 960), framesPerSecond: framesPerSecond),
    ]

    public static let defaultIndex = 1
}
