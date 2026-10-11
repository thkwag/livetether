import AppKit
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
        /// Deactivates, then activates again once the old extension has stopped.
        case reinstall
    }

    /// When an extension replaces another of the same identifier, macOS removes the old extension's
    /// launch job asynchronously and can try to start the new one under the same job label before
    /// the removal finishes; the new extension then does not start until a restart. A deactivation
    /// followed by a separate activation avoids that, so a reinstall waits this long in between.
    private static let reinstallPause: Duration = .seconds(3)

    static let extensionIdentifier = "com.github.thkwag.lumixwebcam.CameraExtension"

    private(set) var state: State = .checking
    @ObservationIgnored private var pendingAction: Action = .inspect
    /// Set when an activation replaces an installed extension or follows a deactivation.
    @ObservationIgnored private var activationSupersedesExtension = false
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

    /// Removes the installed extension and installs the bundled one again; the user approves it again.
    /// Used when a replaced extension did not start, at which point the installed build is the bundled one.
    func reinstall() {
        guard isInApplicationsFolder else {
            state = .outsideApplicationsFolder
            return
        }
        state = .uninstalling
        submit(.deactivationRequest(forExtensionWithIdentifier: Self.extensionIdentifier, queue: .main), action: .reinstall)
    }

    /// A process that was running while its camera extension was replaced, or that started before
    /// the new extension published its camera, keeps its old camera list and never sees the new
    /// camera, so it cannot feed it. An instance started after the camera was published sees it.
    private func relaunch() {
        log.notice("Relaunching to see the camera of the new extension")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { [log] _, error in
            Task { @MainActor in
                if let error {
                    log.error("Relaunch failed: \(error.localizedDescription, privacy: .public)")
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }

    /// An enabled extension whose camera never appears to camera apps has not taken effect; macOS
    /// applies it after a restart. The camera gets a few seconds to appear before saying so, and the
    /// restart notice goes away as soon as the camera appears. After this process replaced the
    /// extension its own camera list is stale (see `relaunch`), so it relaunches instead; the new
    /// instance, started after the wait, decides whether a restart is needed.
    private func confirmDevicePresence(relaunchIfMissing: Bool = false) {
        Task { @MainActor [weak self] in
            for _ in 0..<10 {
                if SinkStreamClient.isVirtualCameraPresent { return }
                try? await Task.sleep(for: .seconds(1))
            }
            guard let self, self.state == .installed else { return }
            if relaunchIfMissing {
                self.relaunch()
                return
            }
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
        log.info("Replacing extension build \(existing.bundleVersion, privacy: .public) with \(ext.bundleVersion, privacy: .public)")
        activationSupersedesExtension = true
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        state = .awaitingApproval
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed:
            switch pendingAction {
            case .deactivate:
                state = .notInstalled
            case .reinstall:
                state = .installing
                activationSupersedesExtension = true
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: Self.reinstallPause)
                    self?.install()
                }
            case .activate:
                state = .installed
                confirmDevicePresence(relaunchIfMissing: activationSupersedesExtension)
                activationSupersedesExtension = false
            case .inspect:
                state = .installed
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
            // An app update carries a new extension; activating it replaces the installed one. A
            // deactivation cannot be used here: it fails while the installed build differs from the
            // bundled one.
            if let bundled = Self.bundledExtensionVersion, enabled.bundleVersion != bundled, isInApplicationsFolder {
                log.info("Installed extension \(enabled.bundleVersion, privacy: .public) differs from bundled \(bundled, privacy: .public)")
                install()
            } else {
                confirmDevicePresence()
            }
        } else if properties.contains(where: { $0.isAwaitingUserApproval }) {
            state = .awaitingApproval
        } else {
            state = .notInstalled
        }
    }
}
