import Foundation
import CoreGraphics

/// One captured picture of the device's display.
public struct FramebufferCapture: Sendable, Equatable {
    /// Encoded image bytes (JPEG) exactly as the capture tool produced them.
    public let data: Data
    public let pixelSize: CGSize
    public let capturedAt: Date

    public init(data: Data, pixelSize: CGSize, capturedAt: Date) {
        self.data = data
        self.pixelSize = pixelSize
        self.capturedAt = capturedAt
    }
}

public enum FramebufferCaptureError: Error, Sendable, Equatable {
    case invalidDevice
    case deviceShutDown
    case toolFailed(String)
    case unreadable

    public var message: String {
        switch self {
        case .invalidDevice: return "The device identifier is not a simulator UDID."
        case .deviceShutDown: return "The simulator is shut down. Boot it, then the live view resumes."
        case .toolFailed(let text): return text
        case .unreadable: return "The capture produced no readable frame."
        }
    }
}

/// Port over reading the simulator's framebuffer. The concrete implementation lives in
/// Infrastructure.
///
/// Read-only by construction: the only operation is "give me the current picture". It has no input,
/// lifecycle or interaction operation, so nothing holding this port can change the device. It is
/// separate from `SimulatorManaging` (lifecycle) and from `SimulatorInteractionPort` (proposals).
public protocol SimulatorFramebufferSource: Sendable {
    func captureFrame(udid: String) async -> Result<FramebufferCapture, FramebufferCaptureError>
    /// Releases whatever the source keeps running between captures (a video stream). Called when nothing is looking at the picture any more.
    func stop()
}

public extension SimulatorFramebufferSource {
    func stop() {}
}
