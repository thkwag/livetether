import Foundation
import LumixProtocol
import LumixVideo
import Observation

/// Downloads the published gaze-warping weights from their original repository on the user's
/// request, keeps them in the app's Application Support folder, and builds the eye contact
/// correction from them. The app itself carries no weights.
@MainActor
@Observable
final class GazeModelStore {
    enum State: Equatable {
        case notDownloaded
        case downloading
        case ready
        case failed(String)
    }

    private(set) var state: State = .notDownloaded
    @ObservationIgnored private(set) var corrector: EyeContactCorrector?
    @ObservationIgnored private let log = LumixLog.logger(category: "gaze-model")
    @ObservationIgnored private let manifest: GazeWeightManifest?

    /// Where the weights are kept, laid out as the manifest's paths.
    let folder: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folder = support.appendingPathComponent("GazeWeights", isDirectory: true)
        do {
            manifest = try GazeWeightManifest.bundled()
        } catch {
            manifest = nil
            log.error("The gaze weight manifest is missing: \(String(describing: error), privacy: .public)")
        }
        load()
    }

    /// The page of the original repository the weights come from.
    var sourcePage: URL? { URL(string: "https://github.com/chihfanhsu/gaze_correction") }

    func download() async {
        guard let manifest else {
            state = .failed(String(localized: "The model description is missing from this build."))
            return
        }
        state = .downloading
        do {
            for file in manifest.files.values {
                guard let url = manifest.url(of: file) else { throw GazeModelError.fileMismatch(file.path) }
                let (location, _) = try await URLSession.shared.download(from: url)
                let data = try Data(contentsOf: location)
                guard GazeWeightManifest.matches(data, file) else { throw GazeModelError.fileMismatch(file.path) }
                let target = folder.appendingPathComponent(file.path)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
            }
            load()
        } catch {
            log.error("Downloading the gaze weights failed: \(String(describing: error), privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }

    func remove() {
        do {
            if FileManager.default.fileExists(atPath: folder.path) {
                try FileManager.default.removeItem(at: folder)
            }
        } catch {
            log.error("Removing the gaze weights failed: \(error.localizedDescription, privacy: .public)")
        }
        corrector = nil
        state = .notDownloaded
    }

    /// Builds the correction from weights downloaded earlier; files that do not match the published
    /// ones are treated as missing.
    private func load() {
        guard let manifest, manifest.files.values.allSatisfy({ FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.path).path) }) else {
            corrector = nil
            if state != .downloading { state = .notDownloaded }
            return
        }
        do {
            corrector = EyeContactCorrector(network: try GazeNetwork(folder: folder, manifest: manifest))
            state = .ready
        } catch {
            log.error("Building the eye contact network failed: \(String(describing: error), privacy: .public)")
            corrector = nil
            state = .failed(String(describing: error))
        }
    }
}
