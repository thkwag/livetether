import Foundation
import LumixProtocol
import LumixSession
import LumixVideo
import Observation

/// The user's preferences, kept in the app's defaults.
@MainActor
@Observable
final class AppSettings {
    private enum Key {
        static let productIDs = "allowedProductIDs"
        static let preferredSizes = "preferredLiveViewSizes"
        static let setupGuideCompleted = "setupGuideCompleted"
        static let autoFramingEnabled = "autoFramingEnabled"
        static let eyeContactEnabled = "eyeContactEnabled"
        static let framingShot = "framingShot"
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let log = LumixLog.logger(category: "settings")

    /// USB product IDs of the Panasonic cameras the app uses.
    private(set) var productIDs: Set<Int>
    /// The live-view size chosen per camera model; a missing entry means the automatic choice.
    private(set) var preferredSizes: [String: LiveViewSize]

    var setupGuideCompleted: Bool {
        didSet { defaults.set(setupGuideCompleted, forKey: Key.setupGuideCompleted) }
    }

    /// Whether the picture is cropped to keep the people in front of the camera framed.
    var autoFramingEnabled: Bool {
        didSet { defaults.set(autoFramingEnabled, forKey: Key.autoFramingEnabled) }
    }

    /// Whether the eyes are redirected toward the camera while the face looks straight ahead.
    var eyeContactEnabled: Bool {
        didSet { defaults.set(eyeContactEnabled, forKey: Key.eyeContactEnabled) }
    }

    /// How much of a person the automatic framing shows.
    var framingShot: FramingShot {
        didSet { defaults.set(framingShot.rawValue, forKey: Key.framingShot) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedIDs = defaults.array(forKey: Key.productIDs) as? [Int]
        productIDs = storedIDs.map(Set.init) ?? CameraFilter.defaultProductIDs
        preferredSizes = [:]
        setupGuideCompleted = defaults.bool(forKey: Key.setupGuideCompleted)
        autoFramingEnabled = defaults.bool(forKey: Key.autoFramingEnabled)
        eyeContactEnabled = defaults.bool(forKey: Key.eyeContactEnabled)
        framingShot = defaults.string(forKey: Key.framingShot).flatMap(FramingShot.init(rawValue:)) ?? .headAndShoulders
        preferredSizes = loadPreferredSizes()
    }

    func preferredSize(for model: String) -> LiveViewSize? {
        preferredSizes[model]
    }

    func setPreferredSize(_ size: LiveViewSize?, for model: String) {
        preferredSizes[model] = size
        do {
            defaults.set(try JSONEncoder().encode(preferredSizes), forKey: Key.preferredSizes)
        } catch {
            log.error("Saving live-view sizes failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func setProductIDs(_ ids: Set<Int>) {
        productIDs = ids
        defaults.set(ids.sorted(), forKey: Key.productIDs)
    }

    private func loadPreferredSizes() -> [String: LiveViewSize] {
        guard let data = defaults.data(forKey: Key.preferredSizes) else { return [:] }
        do {
            return try JSONDecoder().decode([String: LiveViewSize].self, from: data)
        } catch {
            log.error("Stored live-view sizes are unreadable and are ignored: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }
}
