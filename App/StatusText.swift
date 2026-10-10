import AppKit
import Foundation
import LumixProtocol
import LumixSession

/// Localized descriptions of the link and the extension for the menu and the windows.
enum StatusText {
    static func summary(_ status: LinkStatus) -> String {
        let name = status.cameraName ?? String(localized: "the camera")
        switch status.phase {
        case .searching:
            return String(localized: "Waiting for a camera")
        case .opening:
            return String(localized: "Connecting to \(name)")
        case .ready:
            return String(localized: "Connected to \(name)")
        case .startingLiveView:
            return String(localized: "Starting live view on \(name)")
        case .streaming:
            return String(localized: "Streaming from \(name)")
        case .waitingToRetry(_, .openFailed):
            return String(localized: "Cannot open the camera. Another app may be using it.")
        case .waitingToRetry(_, .communicationFailed):
            return String(localized: "Lost contact with the camera. Reconnecting.")
        }
    }

    static func installer(_ state: ExtensionInstaller.State) -> String {
        switch state {
        case .checking:
            return String(localized: "Checking")
        case .notInstalled:
            return String(localized: "Not installed")
        case .installing:
            return String(localized: "Installing")
        case .awaitingApproval:
            return String(localized: "Waiting for approval in System Settings")
        case .installed:
            return String(localized: "Installed")
        case .restartRequired:
            return String(localized: "Restart your Mac to finish")
        case .uninstalling:
            return String(localized: "Uninstalling")
        case .outsideApplicationsFolder:
            return String(localized: "Move LUMIX Webcam to the Applications folder first")
        case .failed(let reason):
            return String(localized: "Failed: \(reason)")
        }
    }

    /// A size as the camera reports it, in pixels and frames per second.
    static func size(_ size: LiveViewSize) -> String {
        "\(size.width) × \(size.height), \(size.framesPerSecond) fps"
    }
}

/// Opens the pane of System Settings where the user approves camera extensions.
enum SystemSettings {
    static let extensionsPane = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")

    static func openExtensions() {
        guard let url = extensionsPane else { return }
        NSWorkspace.shared.open(url)
    }
}
