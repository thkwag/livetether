import Foundation
import LumixVideo

/// The app's link status as the extension needs it to choose the standby text.
public enum LinkIndicator: UInt8, Sendable, CaseIterable {
    /// No fresh status from the app: it is not running or has stopped publishing.
    case appNotRunning = 0
    case waitingForCamera = 1
    case connecting = 2
    /// The session could not be opened; another application may hold the camera.
    case cameraUnavailable = 3
    /// The session is open and live view is starting.
    case preparing = 4
    case streaming = 5
    /// Communication failed; the app will reconnect.
    case communicationError = 6
}

/// A link indicator stamped with the time the app published it, packed into one Darwin notification state.
///
/// Layout: bits 0...7 the indicator, bits 32...63 the publish time in whole seconds since 1970.
/// The app republishes regularly, so a status older than `staleAfter` means the app is gone.
public struct StatusWord: Equatable, Sendable {
    public static let staleAfter: TimeInterval = 6
    public static let republishInterval: Duration = .seconds(2)

    public var indicator: LinkIndicator
    public var publishedAt: UInt32

    public init(indicator: LinkIndicator, publishedAt: Date) {
        self.indicator = indicator
        self.publishedAt = UInt32(clamping: Int64(publishedAt.timeIntervalSince1970.rounded(.down)))
    }

    public init(encoded: UInt64) {
        indicator = LinkIndicator(rawValue: UInt8(truncatingIfNeeded: encoded)) ?? .appNotRunning
        publishedAt = UInt32(truncatingIfNeeded: encoded >> 32)
    }

    public var encoded: UInt64 { UInt64(publishedAt) << 32 | UInt64(indicator.rawValue) }

    /// The indicator to act on at `now`: the published one while fresh, otherwise `.appNotRunning`.
    public func effectiveIndicator(at now: Date) -> LinkIndicator {
        let age = now.timeIntervalSince1970 - TimeInterval(publishedAt)
        guard age <= Self.staleAfter, age >= -Self.staleAfter else { return .appNotRunning }
        return indicator
    }
}

/// What the extension sends for one output frame.
public enum OutputDecision: Equatable, Sendable {
    case cameraFrame
    case standby(StandbyMessage)
}

/// Chooses between the latest camera picture and the standby frame.
public enum OutputPolicy {
    /// A camera picture older than this is no longer shown.
    public static let frameFreshness: TimeInterval = 1

    public static func decide(lastFrameAge: TimeInterval?, indicator: LinkIndicator) -> OutputDecision {
        if let age = lastFrameAge, age >= 0, age <= frameFreshness {
            return .cameraFrame
        }
        return .standby(StandbyCopy.message(for: indicator))
    }
}

/// The standby texts shown in video calls while no camera picture is available.
public enum StandbyCopy {
    public static func message(for indicator: LinkIndicator) -> StandbyMessage {
        switch indicator {
        case .appNotRunning:
            return StandbyMessage(title: "LUMIX Webcam 앱이 실행되지 않았습니다", detail: "앱을 실행하면 카메라 영상이 표시됩니다")
        case .waitingForCamera:
            return StandbyMessage(title: "카메라를 연결해 주세요", detail: "카메라의 USB 모드를 PC(Tether)로 설정하고 USB 케이블로 연결합니다")
        case .connecting:
            return StandbyMessage(title: "카메라에 연결하는 중입니다")
        case .cameraUnavailable:
            return StandbyMessage(title: "카메라에 연결할 수 없습니다", detail: "LUMIX Tether 등 카메라를 사용하는 다른 앱을 종료해 주세요")
        case .preparing, .streaming:
            return StandbyMessage(title: "카메라 영상을 준비하는 중입니다")
        case .communicationError:
            return StandbyMessage(title: "카메라와 통신할 수 없습니다", detail: "잠시 후 다시 연결합니다")
        }
    }
}
