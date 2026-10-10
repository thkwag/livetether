import LumixProtocol
import LumixSession
import SwiftUI

/// The settings window.
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
        Form {
            Section("Camera Extension") {
                LabeledContent("Status") {
                    Text(verbatim: StatusText.installer(model.installer.state))
                }
                HStack {
                    Button("Install") { model.installer.install() }
                        .disabled(model.installer.state == .installed || model.installer.state == .installing)
                    Button("Uninstall") { model.installer.uninstall() }
                        .disabled(model.installer.state != .installed)
                    if model.installer.state == .awaitingApproval {
                        Button("Open System Settings") { SystemSettings.openExtensions() }
                    }
                }
            }
            Section("Startup") {
                Toggle("Open at login", isOn: Binding(
                    get: { model.loginItem.isEnabled },
                    set: { model.loginItem.setEnabled($0) }
                ))
                if let error = model.loginItem.lastError {
                    Text(verbatim: error).foregroundStyle(.red)
                }
            }
            if model.legacyPluginInstalled {
                Section("Earlier Software") {
                    Text("The earlier LUMIX Webcam Software is installed as a DAL plug-in. macOS 14.1 and later do not load it, so it is not used. You can remove it from /Library/CoreMediaIO/Plug-Ins/DAL.")
                }
            }
        }
        .formStyle(.grouped)
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
        Form {
            Section {
                LabeledContent("Camera") {
                    Text(verbatim: status.cameraName ?? String(localized: "Not connected"))
                }
                Picker("Live view size", selection: Binding(
                    get: { model.preferredSizeForCurrentCamera },
                    set: { model.selectLiveViewSize($0) }
                )) {
                    Text("Automatic").tag(LiveViewSize?.none)
                    ForEach(offeredSizes, id: \.self) { size in
                        Text(verbatim: StatusText.size(size)).tag(Optional(size))
                    }
                }
                .disabled(status.cameraName == nil || offeredSizes.isEmpty)
                Text("Automatic uses the widest size the camera offers at 30 fps. The list appears while the camera streams.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Live View") {
                LabeledContent("Current size") {
                    Text(verbatim: status.liveView.map { StatusText.size($0.current) } ?? String(localized: "Not available"))
                }
                LabeledContent("Frames received") {
                    Text(status.statistics.frames, format: .number)
                }
                LabeledContent("Busy replies") {
                    Text(status.statistics.busyReplies, format: .number)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// The USB product IDs the app accepts.
struct AdvancedSettings: View {
    let model: AppModel
    @State private var productIDText = ""
    @State private var showsInvalidInput = false

    var body: some View {
        Form {
            Section("USB Product IDs") {
                TextField("Product IDs", text: $productIDText)
                Text("Only Panasonic USB devices (vendor ID 04DA) with these product IDs are used. Enter hexadecimal IDs separated by commas.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if showsInvalidInput {
                    Text("Enter one or more hexadecimal product IDs, such as 2382.")
                        .foregroundStyle(.red)
                }
                HStack {
                    Button("Restore Default") {
                        productIDText = CameraFilter.formatProductIDs(CameraFilter.defaultProductIDs)
                        apply()
                    }
                    Button("Apply") { apply() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
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
