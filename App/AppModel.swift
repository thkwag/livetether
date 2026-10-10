import AppKit
import Foundation
import LumixImageCapture
import LumixProtocol
import LumixSession
import LumixVideo
import LumixVirtualCamera
import Observation
import os

/// Wires camera discovery, the camera link, the frame pipeline and the extension's status channels.
@MainActor
@Observable
final class AppModel {
    /// The plug-in of the earlier LUMIX Webcam Software, which macOS 14.1 and later no longer load.
    static let legacyPluginPath = "/Library/CoreMediaIO/Plug-Ins/DAL/LUMIXWebcam.plugin"
    static let statusInterval: Duration = .seconds(1)

    let settings: AppSettings
    let installer = ExtensionInstaller()
    let loginItem = LoginItem()
    let gazeModel = GazeModelStore()
    let link: CameraLinkController
    let legacyPluginInstalled: Bool

    /// Whether any application is reading the virtual camera.
    private(set) var clientsActive = false

    @ObservationIgnored private let discovery: ImageCaptureDiscovery
    @ObservationIgnored private let pipeline: FramePipeline
    @ObservationIgnored private var sourceActivity: DarwinStateChannel?
    @ObservationIgnored private var sourceObservation: DarwinObservation?
    @ObservationIgnored private var linkStatus: DarwinStateChannel?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?
    @ObservationIgnored private var setupGuideRequested = false
    @ObservationIgnored private let log = LumixLog.logger(category: "app")

    init() {
        let settings = AppSettings()
        let pipeline = FramePipeline()
        self.settings = settings
        self.pipeline = pipeline
        link = CameraLinkController(frameSink: { pipeline.deliver($0) })
        discovery = ImageCaptureDiscovery(filter: CameraFilter(productIDs: settings.productIDs))
        legacyPluginInstalled = FileManager.default.fileExists(atPath: Self.legacyPluginPath)

        link.preferredSize = { [weak settings] model in settings?.preferredSize(for: model) }
        pipeline.setAutoFraming(settings.autoFramingEnabled, shot: settings.framingShot)
        pipeline.setEyeContact(gazeModel.corrector, enabled: settings.eyeContactEnabled)
        discovery.onEvent = { [weak self] event in self?.link.handle(event) }
        observeSourceActivity()
        publishStatusPeriodically()
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
        discovery.start()
        installer.refresh()
    }

    var menuBarSymbol: String {
        switch link.status.phase {
        case .streaming:
            return "web.camera.fill"
        case .waitingToRetry:
            return "exclamationmark.triangle"
        case .searching, .opening, .ready, .startingLiveView:
            return "web.camera"
        }
    }

    /// Whether the setup guide still has a step for the user.
    var needsSetupGuide: Bool {
        guard settings.setupGuideCompleted else { return true }
        switch installer.state {
        case .notInstalled, .awaitingApproval, .outsideApplicationsFolder, .failed:
            return true
        case .checking, .installing, .installed, .restartRequired, .uninstalling:
            return false
        }
    }

    /// Returns `true` once per launch when the setup guide should open by itself.
    func takeSetupGuideRequest() -> Bool {
        guard needsSetupGuide, !setupGuideRequested else { return false }
        setupGuideRequested = true
        return true
    }

    var preferredSizeForCurrentCamera: LiveViewSize? {
        link.status.cameraName.flatMap { settings.preferredSize(for: $0) }
    }

    func selectLiveViewSize(_ size: LiveViewSize?) {
        guard let model = link.status.cameraName else { return }
        settings.setPreferredSize(size, for: model)
        link.restartLiveView()
    }

    /// Turns the automatic framing on or off; the next picture already follows the choice.
    func setAutoFraming(_ enabled: Bool) {
        settings.autoFramingEnabled = enabled
        pipeline.setAutoFraming(enabled, shot: settings.framingShot)
    }

    func setFramingShot(_ shot: FramingShot) {
        settings.framingShot = shot
        pipeline.setAutoFraming(settings.autoFramingEnabled, shot: shot)
    }

    /// Whether the gaze weights have been downloaded and the correction can run.
    var eyeContactAvailable: Bool { gazeModel.state == .ready }

    func setEyeContact(_ enabled: Bool) {
        settings.eyeContactEnabled = enabled
        pipeline.setEyeContact(gazeModel.corrector, enabled: enabled)
    }

    /// Downloads the gaze weights after the user accepted their terms, then applies the setting.
    func downloadGazeModel() async {
        await gazeModel.download()
        pipeline.setEyeContact(gazeModel.corrector, enabled: settings.eyeContactEnabled)
    }

    func removeGazeModel() {
        gazeModel.remove()
        pipeline.setEyeContact(nil, enabled: false)
    }

    func applyProductIDs(_ ids: Set<Int>) {
        settings.setProductIDs(ids)
        discovery.update(filter: CameraFilter(productIDs: ids))
    }

    // MARK: - Extension channels

    private func observeSourceActivity() {
        do {
            let channel = try DarwinStateChannel(name: VirtualCameraIdentity.sourceActiveNotification)
            sourceActivity = channel
            sourceObservation = try channel.observe(on: .main) { [weak self] value in
                MainActor.assumeIsolated { self?.updateSourceActivity(SourceActivity(value)) }
            }
            updateSourceActivity(SourceActivity(channel.currentValue()))
        } catch {
            log.error("Observing the camera extension's activity failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func updateSourceActivity(_ activity: SourceActivity) {
        pipeline.setOutputSize(activity.format?.size ?? VirtualCameraFormats.all[VirtualCameraFormats.defaultIndex].size)
        setClientsActive(activity.isActive)
    }

    private func setClientsActive(_ active: Bool) {
        guard active != clientsActive else { return }
        clientsActive = active
        link.setClientsActive(active)
        if !active {
            pipeline.stop()
        }
    }

    private func publishStatusPeriodically() {
        do {
            linkStatus = try DarwinStateChannel(name: VirtualCameraIdentity.linkStatusNotification)
        } catch {
            log.error("Publishing the link status is unavailable: \(String(describing: error), privacy: .public)")
            return
        }
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.publishStatus(LinkIndicator(phase: self?.link.status.phase ?? .searching))
                do {
                    try await Task.sleep(for: Self.statusInterval)
                } catch {
                    return
                }
            }
        }
    }

    private func publishStatus(_ indicator: LinkIndicator) {
        let language = StandbyLanguage(preferredLanguages: Bundle.main.preferredLocalizations)
        linkStatus?.publish(StatusWord(indicator: indicator, language: language, publishedAt: Date()).encoded)
    }

    private func shutdown() {
        statusTask?.cancel()
        publishStatus(.appNotRunning)
        pipeline.stop()
        discovery.stop()
    }
}
