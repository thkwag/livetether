import Foundation

/// A size in whole pixels.
public struct PixelSize: Hashable, Sendable, Codable, CustomStringConvertible {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var description: String { "\(width)×\(height)" }
}

/// A rectangle in whole pixels, origin at the top-left corner.
public struct PixelRect: Hashable, Sendable, CustomStringConvertible {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var description: String { "(\(x), \(y)) \(width)×\(height)" }
}

/// Aspect-fit placement of a picture inside an output frame.
public enum AspectFit {
    /// The largest rectangle with the source's aspect ratio that fits in `target`, centered.
    ///
    /// In integer arithmetic, the matching side takes the target's
    /// length, the other side is `source × target ÷ source` rounded down, and the margins are
    /// split with the extra pixel, if any, on the right or bottom.
    public static func rect(fitting source: PixelSize, into target: PixelSize) -> PixelRect {
        guard source.width > 0, source.height > 0, target.width > 0, target.height > 0 else {
            return PixelRect(x: 0, y: 0, width: 0, height: 0)
        }
        let width: Int
        let height: Int
        if source.width * target.height >= target.width * source.height {
            width = target.width
            height = max(1, source.height * target.width / source.width)
        } else {
            height = target.height
            width = max(1, source.width * target.height / source.height)
        }
        return PixelRect(x: (target.width - width) / 2, y: (target.height - height) / 2, width: width, height: height)
    }
}
