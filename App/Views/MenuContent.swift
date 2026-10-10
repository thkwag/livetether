import AppKit
import LumixSession
import SwiftUI

/// The menu bar menu: the link status, then the windows and quitting.
struct MenuContent: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(verbatim: StatusText.summary(model.link.status))
        if case .streaming = model.link.status.phase, let size = model.link.status.liveView?.current {
            Text(verbatim: StatusText.size(size))
        }
        if model.installer.state != .installed {
            Text(verbatim: String(localized: "Camera extension: \(StatusText.installer(model.installer.state))"))
        }
        Toggle("Auto Framing", isOn: Binding(
            get: { model.settings.autoFramingEnabled },
            set: { model.setAutoFraming($0) }
        ))
        if model.eyeContactAvailable {
            Toggle("Eye Contact", isOn: Binding(
                get: { model.settings.eyeContactEnabled },
                set: { model.setEyeContact($0) }
            ))
        }
        Divider()
        Button("Settings…") {
            openSettings()
            NSApp.activate()
        }
        Button("Setup Guide…") {
            openWindow(id: SetupGuideView.windowID)
            NSApp.activate()
        }
        Divider()
        Button("Quit LUMIX Webcam") {
            NSApp.terminate(nil)
        }
    }
}
