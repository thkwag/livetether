import CoreVideo
import Foundation
import os

/// A failure while decoding, composing or drawing a video frame.
public enum VideoError: Error, Equatable, Sendable {
    case decodeFailed
    case bufferCreationFailed(CVReturn)
    case lockFailed(CVReturn)
    case unsupportedPixelFormat(OSType)
    case contextCreationFailed
    case scaleFailed(Int)
    /// A crop rectangle reaches outside the picture.
    case cropOutOfBounds
    /// Finding people in a picture failed.
    case detectionFailed(String)
}

/// Creates IOSurface-backed 32-bit BGRA pixel buffers of one size, reusing released ones.
///
/// IOSurface backing lets a buffer cross from the app to the camera extension without a copy.
public final class PixelBufferPool: Sendable {
    public let size: PixelSize
    // `CVPixelBufferPool` is thread-safe; the box only makes that visible to the compiler.
    private let pool: SendablePool

    public init(size: PixelSize) throws(VideoError) {
        let attributes: [CFString: Any] = [
            kCVPixelBufferWidthKey: size.width,
            kCVPixelBufferHeightKey: size.height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        var created: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &created)
        guard status == kCVReturnSuccess, let created else {
            throw .bufferCreationFailed(status)
        }
        self.size = size
        self.pool = SendablePool(pool: created)
    }

    public func makeBuffer() throws(VideoError) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool.pool, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw .bufferCreationFailed(status)
        }
        return buffer
    }
}

private struct SendablePool: @unchecked Sendable {
    let pool: CVPixelBufferPool
}

/// Keeps one pool per size so callers that see a few sizes reuse their buffers.
public final class PixelBufferPools: Sendable {
    private let pools = OSAllocatedUnfairLock<[PixelSize: PixelBufferPool]>(initialState: [:])

    public init() {}

    public func makeBuffer(size: PixelSize) throws(VideoError) -> CVPixelBuffer {
        let existing = pools.withLock { $0[size] }
        if let existing {
            return try existing.makeBuffer()
        }
        let pool = try PixelBufferPool(size: size)
        pools.withLock { $0[size] = pool }
        return try pool.makeBuffer()
    }
}

extension CVPixelBuffer {
    public var pixelSize: PixelSize {
        PixelSize(width: CVPixelBufferGetWidth(self), height: CVPixelBufferGetHeight(self))
    }

    /// Runs `body` with the buffer's base address locked for the given access.
    func withLockedBase<Result>(readOnly: Bool, _ body: (UnsafeMutableRawPointer, Int) throws(VideoError) -> Result) throws(VideoError) -> Result {
        let flags: CVPixelBufferLockFlags = readOnly ? .readOnly : []
        let status = CVPixelBufferLockBaseAddress(self, flags)
        guard status == kCVReturnSuccess else {
            throw .lockFailed(status)
        }
        defer { CVPixelBufferUnlockBaseAddress(self, flags) }
        guard let base = CVPixelBufferGetBaseAddress(self) else {
            throw .lockFailed(kCVReturnInvalidPixelBufferAttributes)
        }
        return try body(base, CVPixelBufferGetBytesPerRow(self))
    }

    func requireBGRA() throws(VideoError) {
        let format = CVPixelBufferGetPixelFormatType(self)
        guard format == kCVPixelFormatType_32BGRA else {
            throw .unsupportedPixelFormat(format)
        }
    }
}
