import AppKit
import SwiftUI

@main
struct LumixWebcamApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            MenuBarLabel(model: model)
        }

        Settings {
            SettingsView(model: model)
        }

        Window("LUMIX Webcam Setup", id: SetupGuideView.windowID) {
            SetupGuideView(model: model)
        }
        .windowResizability(.contentSize)
    }
}

/// The menu bar icon; it also opens the setup guide when a step still needs the user.
struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: model.menuBarSymbol)
            .task { openSetupGuideIfNeeded() }
            .onChange(of: model.needsSetupGuide) { openSetupGuideIfNeeded() }
    }

    private func openSetupGuideIfNeeded() {
        guard model.takeSetupGuideRequest() else { return }
        openWindow(id: SetupGuideView.windowID)
        NSApp.activate()
    }
}
