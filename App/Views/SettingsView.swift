import LumixProtocol
import LumixSession
import LumixVideo
import SwiftUI

/// The settings window. Every tab is laid out in plain stacks rather than a scrolling form, so the
/// window always grows to its content: nothing scrolls and no text is cut short.
struct SettingsView: View {
    let model: AppModel

    var body: some View {
        TabView {
            GeneralSettings(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            CameraSettings(model: model)
                .tabItem { Label("Camera", systemImage: "camera") }
            AdvancedSettings(model: model)
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The camera extension, the login item and the earlier software.
struct GeneralSettings: View {
    let model: AppModel

    var body: some View {
        SettingsPane {
            SettingsGroup("Camera Extension") {
                LabeledContent("Status") {
                    Text(verbatim: StatusText.installer(model.installer.state))
                        .foregroundStyle(.secondary)
                }
                Divider()
                HStack {
                    Button("Install") { model.installer.install() }
                        .disabled(model.installer.state == .installed || model.installer.state == .installing)
                    Button("Uninstall") { model.installer.uninstall() }
                        .disabled(model.installer.state != .installed && model.installer.state != .restartRequired)
                    if model.installer.state == .awaitingApproval {
                        Button("Open System Settings") { SystemSettings.openExtensions() }
                    }
                }
            }
            SettingsGroup("Startup") {
                LabeledContent("Open at login") {
                    Toggle("Open at login", isOn: Binding(
                        get: { model.loginItem.isEnabled },
                        set: { model.loginItem.setEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                if let error = model.loginItem.lastError {
                    Text(verbatim: error)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if model.legacyPluginInstalled {
                SettingsGroup("Earlier Software") {
                    Text("The earlier LUMIX Webcam Software is installed as a DAL plug-in. macOS 14.1 and later do not load it, so it is not used. You can remove it from /Library/CoreMediaIO/Plug-Ins/DAL.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// The connected camera, its live-view size and frame counts.
struct CameraSettings: View {
    let model: AppModel

    private var offeredSizes: [LiveViewSize] {
        model.link.status.liveView?.available.filter { $0.framesPerSecond == 30 } ?? []
    }

    var body: some View {
        let status = model.link.status
        SettingsPane {
            SettingsGroup {
                LabeledContent("Camera") {
                    Text(verbatim: status.cameraName ?? String(localized: "Not connected"))
                        .foregroundStyle(.secondary)
                }
                Divider()
                LabeledContent("Live view size") {
                    Picker("Live view size", selection: Binding(
                        get: { model.preferredSizeForCurrentCamera },
                        set: { model.selectLiveViewSize($0) }
                    )) {
                        Text("Automatic").tag(LiveViewSize?.none)
                        ForEach(offeredSizes, id: \.self) { size in
                            Text(verbatim: StatusText.size(size)).tag(Optional(size))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(status.cameraName == nil || offeredSizes.isEmpty)
                }
                SettingsNote("Automatic uses the widest size the camera offers at 30 fps. The list appears while the camera streams.")
            }
            SettingsGroup("Auto Framing") {
                LabeledContent("Auto Framing") {
                    Toggle("Auto Framing", isOn: Binding(
                        get: { model.settings.autoFramingEnabled },
                        set: { model.setAutoFraming($0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                LabeledContent("Shot") {
                    Picker("Shot", selection: Binding(
                        get: { model.settings.framingShot },
                        set: { model.setFramingShot($0) }
                    )) {
                        Text("Head and shoulders").tag(FramingShot.headAndShoulders)
                        Text("Upper body").tag(FramingShot.upperBody)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsNote("Keeps the people in front of the camera in the middle of the picture and follows them as they move, giving room on the side they look to. People are found on this Mac only; no picture is stored or sent.")
            }
            SettingsGroup("Eye Contact") {
                LabeledContent("Eye Contact") {
                    Toggle("Eye Contact", isOn: Binding(
                        get: { model.settings.eyeContactEnabled && model.eyeContactAvailable },
                        set: { model.setEyeContact($0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(!model.eyeContactAvailable)
                }
                SettingsNote("Moves the eyes so they look into the camera while the face looks straight ahead, and fades out as the head turns. The eyes are changed on this Mac only.")
                Divider()
                GazeModelRow(model: model)
            }
            SettingsGroup("Live View") {
                LabeledContent("Current size") {
                    Text(verbatim: status.liveView.map { StatusText.size($0.current) } ?? String(localized: "Not available"))
                        .foregroundStyle(.secondary)
                }
                Divider()
                LabeledContent("Frames received") {
                    Text(status.statistics.frames, format: .number)
                        .foregroundStyle(.secondary)
                }
                Divider()
                LabeledContent("Busy replies") {
                    Text(status.statistics.busyReplies, format: .number)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// The USB product IDs the app accepts.
struct AdvancedSettings: View {
    let model: AppModel
    @State private var productIDText = ""
    @State private var showsInvalidInput = false

    var body: some View {
        SettingsPane {
            SettingsGroup("USB Product IDs") {
                LabeledContent("Product IDs") {
                    TextField("Product IDs", text: $productIDText)
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: 240)
                }
                SettingsNote("Only Panasonic USB devices (vendor ID 04DA) with these product IDs are used. Enter hexadecimal IDs separated by commas.")
                if showsInvalidInput {
                    Text("Enter one or more hexadecimal product IDs, such as 2382.")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                HStack {
                    Spacer()
                    Button("Restore Default") {
                        productIDText = CameraFilter.formatProductIDs(CameraFilter.defaultProductIDs)
                        apply()
                    }
                    Button("Apply") { apply() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .onAppear { productIDText = CameraFilter.formatProductIDs(model.settings.productIDs) }
    }

    private func apply() {
        guard let ids = CameraFilter.parseProductIDs(productIDText) else {
            showsInvalidInput = true
            return
        }
        showsInvalidInput = false
        model.applyProductIDs(ids)
        productIDText = CameraFilter.formatProductIDs(ids)
    }
}

/// The content of one settings tab: its groups stacked at their natural height.
struct SettingsPane<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .labeledContentStyle(SettingsRowStyle())
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A titled group of rows on a rounded background, as in a grouped form.
struct SettingsGroup<Content: View>: View {
    let title: LocalizedStringKey?
    let content: Content

    init(_ title: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

/// Secondary text under a row; it wraps instead of being cut short.
struct SettingsNote: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A settings row: the label on the leading edge and the value or control on the trailing edge.
/// Both sides wrap onto more lines rather than being cut short.
struct SettingsRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            configuration.content
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The gaze model: where it comes from, its terms, and downloading or removing it.
struct GazeModelRow: View {
    let model: AppModel
    @State private var confirmsDownload = false

    var body: some View {
        LabeledContent("Model") {
            Text(verbatim: status).foregroundStyle(.secondary)
        }
        SettingsNote("Eye Contact uses the gaze model of \"Look at Me! Correcting Eye Gaze in Live Video Communication\" (Hsu et al., 2019). Its code and weights are published under the BSD 3-Clause license; the weights were trained on data offered for non-commercial use only. LUMIX Webcam does not include them: they are downloaded from the authors' repository when you ask.")
        HStack {
            if let page = model.gazeModel.sourcePage {
                Link("Model Source", destination: page)
            }
            Spacer()
            switch model.gazeModel.state {
            case .ready:
                Button("Remove Model") { model.removeGazeModel() }
            case .downloading:
                ProgressView().controlSize(.small)
            case .notDownloaded, .failed:
                Button("Download Model…") { confirmsDownload = true }
            }
        }
        .confirmationDialog("Download the eye contact model?", isPresented: $confirmsDownload) {
            Button("Accept and Download") {
                Task { await model.downloadGazeModel() }
            }
        } message: {
            Text("About 6 MB is downloaded from github.com/chihfanhsu/gaze_correction. The weights may be used for non-commercial purposes only. Download only if your use is non-commercial.")
        }
    }

    private var status: String {
        switch model.gazeModel.state {
        case .notDownloaded: String(localized: "Not downloaded")
        case .downloading: String(localized: "Downloading")
        case .ready: String(localized: "Ready")
        case .failed(let reason): String(localized: "Failed: \(reason)")
        }
    }
}
