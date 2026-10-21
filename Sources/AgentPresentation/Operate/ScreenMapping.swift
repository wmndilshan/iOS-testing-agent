import Foundation
import CoreGraphics
import AgentCore

/// Maps between a click on the live view and a point on the device screen, for taking over from the agent and for the highlight ring.
/// The picture is drawn aspect-fit inside the view with a small inset; the device's points are its pixels divided by the screen scale.
public struct ScreenMapping: Equatable, Sendable {
    public let viewSize: CGSize
    public let pixelSize: CGSize
    public let inset: CGFloat

    public init(viewSize: CGSize, pixelSize: CGSize, inset: CGFloat = 4) {
        self.viewSize = viewSize
        self.pixelSize = pixelSize
        self.inset = inset
    }

    /// Simulator screenshots are in pixels. Phones are 3x from about 1100 pixels wide, older and smaller ones and iPads 2x.
    public var scale: CGFloat { pixelSize.width >= 1100 && pixelSize.width <= 1400 ? 3 : 2 }
    public var deviceSize: CGSize { CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale) }

    /// Where the picture is inside the view.
    public var imageRect: CGRect {
        guard pixelSize.width > 0, pixelSize.height > 0, viewSize.width > 0, viewSize.height > 0 else { return .zero }
        let available = CGSize(width: max(1, viewSize.width - inset * 2), height: max(1, viewSize.height - inset * 2))
        let ratio = min(available.width / pixelSize.width, available.height / pixelSize.height)
        let size = CGSize(width: pixelSize.width * ratio, height: pixelSize.height * ratio)
        return CGRect(x: (viewSize.width - size.width) / 2, y: (viewSize.height - size.height) / 2, width: size.width, height: size.height)
    }

    /// The device point under a click, or nil when the click is outside the picture.
    public func devicePoint(forViewPoint point: CGPoint) -> DevicePoint? {
        let rect = imageRect
        guard rect.width > 0, rect.contains(point) else { return nil }
        let device = deviceSize
        return DevicePoint(x: ((point.x - rect.minX) / rect.width * device.width).rounded(), y: ((point.y - rect.minY) / rect.height * device.height).rounded())
    }

    /// Where a device point is drawn in the view.
    public func viewPoint(forDevice point: DevicePoint) -> CGPoint {
        let rect = imageRect, device = deviceSize
        guard device.width > 0, device.height > 0 else { return .zero }
        return CGPoint(x: rect.minX + point.x / device.width * rect.width, y: rect.minY + point.y / device.height * rect.height)
    }
}
