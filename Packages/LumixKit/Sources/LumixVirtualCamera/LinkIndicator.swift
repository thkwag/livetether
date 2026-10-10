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

/// The languages the standby texts are localized into.
public enum StandbyLanguage: UInt8, Sendable, CaseIterable {
    case english = 0
    case korean = 1
    case japanese = 2

    /// The `.lproj` name of the language.
    public var localization: String {
        switch self {
        case .english: return "en"
        case .korean: return "ko"
        case .japanese: return "ja"
        }
    }

    /// The first supported language among `preferredLanguages` (BCP 47 tags such as `ko-KR`), else English.
    public init(preferredLanguages: [String]) {
        for tag in preferredLanguages {
            let primary = tag.split(separator: "-").first.map(String.init)?.lowercased()
            if let match = StandbyLanguage.allCases.first(where: { $0.localization == primary }) {
                self = match
                return
            }
        }
        self = .english
    }
}

/// A link indicator and the user's language, stamped with the time the app published them,
/// packed into one Darwin notification state.
///
/// Layout: bits 0...7 the indicator, bits 8...15 the language, bits 32...63 the publish time in
/// whole seconds since 1970. The app republishes regularly, so a status older than `staleAfter`
/// means the app is gone. The language travels with the status because the extension runs as a
/// different user and cannot read the user's language preference itself.
public struct StatusWord: Equatable, Sendable {
    public static let staleAfter: TimeInterval = 6
    public static let republishInterval: Duration = .seconds(2)

    public var indicator: LinkIndicator
    public var language: StandbyLanguage
    public var publishedAt: UInt32

    public init(indicator: LinkIndicator, language: StandbyLanguage, publishedAt: Date) {
        self.indicator = indicator
        self.language = language
        self.publishedAt = UInt32(clamping: Int64(publishedAt.timeIntervalSince1970.rounded(.down)))
    }

    public init(encoded: UInt64) {
        indicator = LinkIndicator(rawValue: UInt8(truncatingIfNeeded: encoded)) ?? .appNotRunning
        language = StandbyLanguage(rawValue: UInt8(truncatingIfNeeded: encoded >> 8)) ?? .english
        publishedAt = UInt32(truncatingIfNeeded: encoded >> 32)
    }

    public var encoded: UInt64 {
        UInt64(publishedAt) << 32 | UInt64(language.rawValue) << 8 | UInt64(indicator.rawValue)
    }

    /// Whether the status was published recently enough to describe the app's current state.
    public func isFresh(at now: Date) -> Bool {
        let age = now.timeIntervalSince1970 - TimeInterval(publishedAt)
        return age <= Self.staleAfter && age >= -Self.staleAfter
    }

    /// The indicator to act on at `now`: the published one while fresh, otherwise `.appNotRunning`.
    public func effectiveIndicator(at now: Date) -> LinkIndicator {
        isFresh(at: now) ? indicator : .appNotRunning
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

    public static func decide(lastFrameAge: TimeInterval?, indicator: LinkIndicator, language: StandbyLanguage) -> OutputDecision {
        if let age = lastFrameAge, age >= 0, age <= frameFreshness {
            return .cameraFrame
        }
        return .standby(StandbyCopy.message(for: indicator, language: language))
    }
}

/// The standby texts shown in video calls while no camera picture is available, from the
/// module's `Localizable.strings` in each supported language.
public enum StandbyCopy {
    public static func message(for indicator: LinkIndicator, language: StandbyLanguage) -> StandbyMessage {
        let key = keyStem(for: indicator)
        let title = text("standby.\(key).title", language: language)
        let detail = hasDetail(indicator) ? text("standby.\(key).detail", language: language) : nil
        return StandbyMessage(title: title, detail: detail)
    }

    /// Every key the standby texts use, for completeness checks of the translations.
    public static var allKeys: [String] {
        LinkIndicator.allCases.reduce(into: [String]()) { keys, indicator in
            let stem = keyStem(for: indicator)
            if !keys.contains("standby.\(stem).title") {
                keys.append("standby.\(stem).title")
            }
            if hasDetail(indicator), !keys.contains("standby.\(stem).detail") {
                keys.append("standby.\(stem).detail")
            }
        }
    }

    /// The translation of `key` in `language`, or `nil` when that language's table lacks it.
    public static func translation(_ key: String, language: StandbyLanguage) -> String? {
        guard let bundle = bundle(for: language) else { return nil }
        let missing = "\u{0}missing"
        let value = bundle.localizedString(forKey: key, value: missing, table: nil)
        return value == missing ? nil : value
    }

    private static func text(_ key: String, language: StandbyLanguage) -> String {
        translation(key, language: language) ?? translation(key, language: .english) ?? key
    }

    private static func keyStem(for indicator: LinkIndicator) -> String {
        switch indicator {
        case .appNotRunning: return "appNotRunning"
        case .waitingForCamera: return "waitingForCamera"
        case .connecting: return "connecting"
        case .cameraUnavailable: return "cameraUnavailable"
        case .preparing, .streaming: return "preparing"
        case .communicationError: return "communicationError"
        }
    }

    private static func hasDetail(_ indicator: LinkIndicator) -> Bool {
        switch indicator {
        case .appNotRunning, .waitingForCamera, .cameraUnavailable, .communicationError: return true
        case .connecting, .preparing, .streaming: return false
        }
    }

    private static func bundle(for language: StandbyLanguage) -> Bundle? {
        Bundle.module.path(forResource: language.localization, ofType: "lproj").flatMap(Bundle.init(path:))
    }
}
