import LumixSession
import SwiftUI

/// The setup guide: the steps from installing the extension to choosing the camera in an app.
/// Every text takes its full height, so the window grows to fit it instead of cutting it short.
struct SetupGuideView: View {
    static let windowID = "setup-guide"

    let model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Set Up LUMIX Webcam")
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            GuideStep(number: 1, title: "Run from the Applications folder", done: model.installer.isInApplicationsFolder) {
                Text("The camera extension can only be installed while LUMIX Webcam runs from the Applications folder.")
            }

            GuideStep(number: 2, title: "Install the camera extension", done: model.installer.state == .installed) {
                Text(verbatim: StatusText.installer(model.installer.state))
                Text("After you click Install, allow LUMIX Webcam in System Settings > General > Login Items & Extensions > Camera Extensions.")
                HStack {
                    Button("Install") { model.installer.install() }
                        .disabled(model.installer.state == .installed || model.installer.state == .installing)
                    Button("Open System Settings") { SystemSettings.openExtensions() }
                }
            }

            GuideStep(number: 3, title: "Connect the camera", done: model.link.status.cameraName != nil) {
                Text("Set the camera's USB mode to PC (Tether) and connect it to this Mac with a USB cable. Avoid USB hubs and charge-only ports.")
            }

            GuideStep(number: 4, title: "Choose LUMIX Webcam as the camera", done: model.clientsActive) {
                Text("In any app that uses a camera, such as FaceTime, Zoom, OBS or QuickTime Player, choose LUMIX Webcam.")
            }

            if model.legacyPluginInstalled {
                Text("The earlier LUMIX Webcam Software is still installed. macOS 14.1 and later do not load it, and LUMIX Webcam replaces it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Done") {
                    model.settings.setupGuideCompleted = true
                    dismissWindow(id: Self.windowID)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One numbered step, with a check mark once it is done.
struct GuideStep<Content: View>: View {
    let number: Int
    let title: LocalizedStringKey
    let done: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                .font(.title2)
                .foregroundStyle(done ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                content
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
