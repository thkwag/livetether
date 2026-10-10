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

/// Decides which attached devices are LUMIX cameras the link should use: USB devices with Panasonic's
/// vendor ID that accept PTP commands and whose product ID is in the configurable allowlist.
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

    /// Parses a comma- or space-separated list of hexadecimal USB product IDs such as `2382, 0x2374`;
    /// `nil` when the list is empty or any entry is not a 16-bit hexadecimal number.
    public static func parseProductIDs(_ text: String) -> Set<Int>? {
        let entries = text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
        guard !entries.isEmpty else { return nil }
        var ids: Set<Int> = []
        for entry in entries {
            let digits = entry.lowercased().hasPrefix("0x") ? String(entry.dropFirst(2)) : entry
            guard !digits.isEmpty, digits.count <= 4, let value = Int(digits, radix: 16) else { return nil }
            ids.insert(value)
        }
        return ids
    }

    /// Formats product IDs as sorted four-digit hexadecimal numbers separated by commas.
    public static func formatProductIDs(_ ids: Set<Int>) -> String {
        ids.sorted().map { String(format: "%04X", $0) }.joined(separator: ", ")
    }
}
