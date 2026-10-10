import Foundation

/// What the extension publishes on the source-active channel: whether any application reads the
/// virtual camera, and in which format.
///
/// The value is 0 while nobody reads the camera. Otherwise bit 0 is set and bits 8 to 15 hold the
/// active format's index plus one, so a reader that only tests for 0 still sees the activity.
public struct SourceActivity: Equatable, Sendable {
    public let isActive: Bool
    /// The index into `VirtualCameraFormats.all` of the format being read; `nil` when not reported.
    public let formatIndex: Int?

    public init(isActive: Bool, formatIndex: Int?) {
        self.isActive = isActive
        self.formatIndex = isActive ? formatIndex : nil
    }

    public init(_ value: UInt64) {
        isActive = value & 1 == 1
        let stored = Int((value >> 8) & 0xFF)
        if isActive, stored > 0, stored - 1 < VirtualCameraFormats.all.count {
            formatIndex = stored - 1
        } else {
            formatIndex = nil
        }
    }

    public var encoded: UInt64 {
        guard isActive else { return 0 }
        return 1 | UInt64((formatIndex ?? -1) + 1) << 8
    }

    /// The output size the reader receives, when the format is known.
    public var format: StreamFormat? {
        formatIndex.map { VirtualCameraFormats.all[$0] }
    }
}
