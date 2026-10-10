import Foundation

/// An attached camera the link can open a session with.
public protocol CameraEndpoint: Sendable {
    var id: CameraID { get }
    /// The name the camera reports, used for display and to key per-model settings.
    var modelName: String { get }
    func makeTransport() -> any PTPTransport
}

/// A change in the set of attached cameras.
public enum DiscoveryEvent: Sendable {
    case appeared(any CameraEndpoint)
    case disappeared(CameraID)
}

/// Decides which attached devices are LUMIX cameras the link should use.
public struct CameraFilter: Sendable, Equatable {
    public static let panasonicVendorID = 0x04DA
    public static let defaultProductIDs: Set<Int> = [0x2382]

    public var productIDs: Set<Int>

    public init(productIDs: Set<Int> = CameraFilter.defaultProductIDs) {
        self.productIDs = productIDs
    }

    public func accepts(vendorID: Int, productID: Int, isUSB: Bool, acceptsPTPCommands: Bool) -> Bool {
        isUSB && acceptsPTPCommands && vendorID == Self.panasonicVendorID && productIDs.contains(productID)
    }
}
