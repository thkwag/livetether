import Foundation
@preconcurrency import ImageCaptureCore
import LumixProtocol
import LumixSession

/// An attached camera found by ImageCaptureCore.
struct ImageCaptureEndpoint: CameraEndpoint, @unchecked Sendable {
    // `ICCameraDevice` is not Sendable; the endpoint only hands it to the transport, which confines it to the main thread.
    let id: CameraID
    let modelName: String
    let camera: ICCameraDevice

    func makeTransport() -> any PTPTransport {
        ImageCaptureTransport(camera: camera)
    }
}

/// Finds attached LUMIX cameras with ImageCaptureCore and reports them as discovery events.
@MainActor
public final class ImageCaptureDiscovery: NSObject {
    public var onEvent: ((DiscoveryEvent) -> Void)?
    public private(set) var filter: CameraFilter

    private let browser = ICDeviceBrowser()
    private let cameraDelegate = CameraDeviceDelegate()
    private var reported: [CameraID: ICCameraDevice] = [:]
    private let log = LumixLog.logger(category: "discovery")

    public init(filter: CameraFilter) {
        self.filter = filter
        super.init()
    }

    public func start() {
        guard !browser.isBrowsing else { return }
        browser.delegate = self
        let mask = ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: mask) ?? .camera
        browser.start()
    }

    public func stop() {
        browser.stop()
        for id in reported.keys {
            onEvent?(.disappeared(id))
        }
        reported.removeAll()
    }

    /// Applies a changed filter to the devices already attached.
    public func update(filter: CameraFilter) {
        self.filter = filter
        let attached = (browser.devices ?? []).compactMap { $0 as? ICCameraDevice }
        for camera in attached {
            evaluate(camera)
        }
    }

    private func evaluate(_ camera: ICCameraDevice) {
        let id = Self.identifier(of: camera)
        let eligible = filter.accepts(
            vendorID: Int(camera.usbVendorID),
            productID: Int(camera.usbProductID),
            isUSB: camera.transportType == ICDeviceTransport.transportTypeUSB.rawValue,
            acceptsPTPCommands: camera.capabilities.contains(ICDeviceCapability.cameraDeviceCanAcceptPTPCommands.rawValue)
        )
        if eligible, reported[id] == nil {
            camera.delegate = cameraDelegate
            reported[id] = camera
            let name = camera.name ?? "LUMIX"
            log.info("Camera appeared: \(name, privacy: .public) \(String(format: "%04x:%04x", camera.usbVendorID, camera.usbProductID), privacy: .public)")
            onEvent?(.appeared(ImageCaptureEndpoint(id: id, modelName: name, camera: camera)))
        } else if !eligible, reported[id] != nil {
            reported[id] = nil
            onEvent?(.disappeared(id))
        }
    }

    private static func identifier(of device: ICDevice) -> CameraID {
        CameraID(device.uuidString ?? String(describing: ObjectIdentifier(device)))
    }
}

extension ImageCaptureDiscovery: @preconcurrency ICDeviceBrowserDelegate {
    public func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice else { return }
        evaluate(camera)
    }

    public func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        let id = Self.identifier(of: device)
        guard reported.removeValue(forKey: id) != nil else { return }
        log.info("Camera removed: \(device.name ?? "?", privacy: .public)")
        onEvent?(.disappeared(id))
    }
}
