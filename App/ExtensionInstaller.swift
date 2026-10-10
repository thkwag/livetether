import Foundation
import LumixProtocol
import LumixVirtualCamera
import Observation
import SystemExtensions

/// Installs, removes and reports the camera extension through the System Extensions framework.
@MainActor
@Observable
final class ExtensionInstaller: NSObject {
    enum State: Equatable {
        case checking
        case notInstalled
        case installing
        case awaitingApproval
        case installed
        case restartRequired
        case uninstalling
        case outsideApplicationsFolder
        case failed(String)
    }

    private enum Action {
        case inspect
        case activate
        case deactivate
    }

    static let extensionIdentifier = "com.github.thkwag.lumixwebcam.CameraExtension"

    private(set) var state: State = .checking
    @ObservationIgnored private var pendingAction: Action = .inspect
    @ObservationIgnored private let log = LumixLog.logger(category: "installer")

    /// System extensions can only be activated by an app inside the Applications folder.
    var isInApplicationsFolder: Bool {
        Bundle.main.bundleURL.deletingLastPathComponent().path == "/Applications"
    }

    /// The build number of the extension inside this app bundle.
    static var bundledExtensionVersion: String? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions/\(extensionIdentifier).systemextension")
        return Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    func refresh() {
        submit(.propertiesRequest(forExtensionWithIdentifier: Self.extensionIdentifier, queue: .main), action: .inspect)
    }

    func install() {
        guard isInApplicationsFolder else {
            state = .outsideApplicationsFolder
            return
        }
        state = .installing
        submit(.activationRequest(forExtensionWithIdentifier: Self.extensionIdentifier, queue: .main), action: .activate)
    }

    func uninstall() {
        state = .uninstalling
        submit(.deactivationRequest(forExtensionWithIdentifier: Self.extensionIdentifier, queue: .main), action: .deactivate)
    }

    /// An enabled extension whose camera never appears to camera apps has not taken effect; macOS
    /// applies it after a restart. The camera gets a few seconds to appear before saying so, and the
    /// restart notice goes away as soon as the camera appears.
    private func confirmDevicePresence() {
        Task { @MainActor [weak self] in
            for _ in 0..<10 {
                if SinkStreamClient.isVirtualCameraPresent { return }
                try? await Task.sleep(for: .seconds(1))
            }
            guard let self, self.state == .installed else { return }
            self.log.notice("The extension is enabled but its camera did not appear")
            self.state = .restartRequired
            // The camera can still arrive late, or after the extension is installed again.
            while self.state == .restartRequired {
                try? await Task.sleep(for: .seconds(5))
                if SinkStreamClient.isVirtualCameraPresent, self.state == .restartRequired {
                    self.state = .installed
                }
            }
        }
    }

    private func submit(_ request: OSSystemExtensionRequest, action: Action) {
        pendingAction = action
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }
}

extension ExtensionInstaller: @preconcurrency OSSystemExtensionRequestDelegate {
    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        log.info("Replacing extension \(existing.bundleShortVersion, privacy: .public) with \(ext.bundleShortVersion, privacy: .public)")
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        state = .awaitingApproval
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed:
            state = pendingAction == .deactivate ? .notInstalled : .installed
            if pendingAction == .activate {
                confirmDevicePresence()
            }
        case .willCompleteAfterReboot:
            state = .restartRequired
        @unknown default:
            state = .failed(String(describing: result))
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: any Error) {
        log.error("Extension request failed: \(error.localizedDescription, privacy: .public)")
        state = .failed(error.localizedDescription)
    }

    func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        if let enabled = properties.first(where: { $0.isEnabled }) {
            state = .installed
            confirmDevicePresence()
            // An app update carries a new extension; activating it replaces the installed one.
            if let bundled = Self.bundledExtensionVersion, enabled.bundleVersion != bundled, isInApplicationsFolder {
                log.info("Installed extension \(enabled.bundleVersion, privacy: .public) differs from bundled \(bundled, privacy: .public)")
                install()
            }
        } else if properties.contains(where: { $0.isAwaitingUserApproval }) {
            state = .awaitingApproval
        } else {
            state = .notInstalled
        }
    }
}
