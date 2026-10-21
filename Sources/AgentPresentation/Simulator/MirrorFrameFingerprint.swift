import Foundation
import CoreGraphics
import ImageIO
import AgentCore

/// A coarse luminance thumbnail of one frame, used for two things only:
///
/// * skipping a frame that is identical to the one already shown (no image rebuild, no redraw), and
/// * noticing that the screen changed *since the accessibility snapshot was taken*, e.g. because
///   someone used Simulator.app, an XCUITest ran or a workflow acted. Then the snapshot's element
///   geometry may no longer describe the screen, and the mirror asks for a fresh observation before
///   it proposes anything.
///
/// It never identifies elements: element identity comes only from accessibility snapshots.
public struct MirrorFrameFingerprint: Sendable, Equatable {
    public static let side = 16
    /// Rows at the top that are ignored so the status-bar clock does not count as a screen change.
    /// A fraction of the image height, not a device constant.
    public static let ignoredTopFraction: Double = 0.07
    /// Mean per-cell luminance difference (0...255) above which two frames show different screens.
    public static let changeThreshold: Double = 6

    /// `side * side` luminance cells, row-major.
    public let cells: [UInt8]

    public init?(cells: [UInt8]) {
        guard cells.count == Self.side * Self.side else { return nil }
        self.cells = cells
    }

    /// Mean absolute per-cell difference.
    public func distance(to other: MirrorFrameFingerprint) -> Double {
        var total = 0
        for i in 0..<cells.count { total += abs(Int(cells[i]) - Int(other.cells[i])) }
        return Double(total) / Double(cells.count)
    }

    public func differs(from other: MirrorFrameFingerprint?) -> Bool {
        guard let other else { return true }
        return distance(to: other) > Self.changeThreshold
    }

    /// Downsamples an encoded image (JPEG/PNG) into a fingerprint.
    public static func make(fromEncoded data: Data) -> MirrorFrameFingerprint? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return make(from: image)
    }

    public static func make(from image: CGImage) -> MirrorFrameFingerprint? {
        let skip = Int(Double(image.height) * ignoredTopFraction)
        guard image.height - skip > 0,
              let body = image.cropping(to: CGRect(x: 0, y: skip, width: image.width, height: image.height - skip)) else { return nil }
        var pixels = [UInt8](repeating: 0, count: side * side)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(body, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn ? MirrorFrameFingerprint(cells: pixels) : nil
    }
}
