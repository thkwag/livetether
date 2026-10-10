import Foundation
import LumixProtocol
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
        if properties.contains(where: { $0.isEnabled }) {
            state = .installed
        } else if properties.contains(where: { $0.isAwaitingUserApproval }) {
            state = .awaitingApproval
        } else {
            state = .notInstalled
        }
    }
}
