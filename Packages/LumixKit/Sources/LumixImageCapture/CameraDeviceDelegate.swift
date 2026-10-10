import Foundation
@preconcurrency import ImageCaptureCore
import LumixProtocol

/// The delegate ImageCaptureCore requires on a camera before sessions are opened on it.
///
/// The webcam uses only the PTP pass-through, so the media catalog notifications are not acted on;
/// they are logged at debug level so a trace shows what ImageCaptureCore did with the camera.
/// Removal is handled by `ImageCaptureDiscovery` through the device browser.
final class CameraDeviceDelegate: NSObject, ICCameraDeviceDelegate, @unchecked Sendable {
    private let log = LumixLog.logger(category: "camera-delegate")

    func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        log.debug("Session opened on \(device.name ?? "?", privacy: .public), error: \(String(describing: error), privacy: .public)")
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {
        log.debug("Session closed on \(device.name ?? "?", privacy: .public), error: \(String(describing: error), privacy: .public)")
    }

    func didRemove(_ device: ICDevice) {
        log.debug("Device removed: \(device.name ?? "?", privacy: .public)")
    }

    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        log.debug("Catalog added \(items.count) items")
    }

    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        log.debug("Catalog removed \(items.count) items")
    }

    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: (any Error)?) {
        log.debug("Thumbnail for \(item.name ?? "?", privacy: .public) ignored")
    }

    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: (any Error)?) {
        log.debug("Metadata for \(item.name ?? "?", privacy: .public) ignored")
    }

    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {
        log.debug("Catalog renamed \(items.count) items")
    }

    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {
        log.debug("Capabilities changed: \(camera.capabilities, privacy: .public)")
    }

    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {
        log.debug("PTP event \(eventData.map { String(format: "%02x", $0) }.joined(), privacy: .public)")
    }

    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        log.debug("Catalog complete on \(device.name ?? "?", privacy: .public)")
    }

    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        log.debug("Access restriction removed on \(device.name ?? "?", privacy: .public)")
    }

    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        log.debug("Access restriction enabled on \(device.name ?? "?", privacy: .public)")
    }
}
