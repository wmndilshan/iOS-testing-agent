import Foundation
import AppKit
import AgentCore

/// Live picture of the real simulator's display for the embedded viewport.
///
/// Frames come from the booted device itself through `SimulatorFramebufferSource` (read-only, injected
/// by the composition root), polled while at least one viewport is attached and the app is active.
/// What the viewport shows is the actual simulator screen, not a stored image. This type only ever
/// reads pixels: it has no input path. Gestures on the mirror go through `MirrorInteractionController`
/// and the approval flow, never through here.
///
/// Cost control: a frame byte-identical to the one on screen is not decoded into a new image, so
/// SwiftUI does not redraw; after a run of visually unchanged frames polling backs
/// off to `idleInterval`; `requestImmediateFrame()` wakes the loop at once (after an action finishes).
@MainActor
public final class SimulatorMirror: ObservableObject {
    @Published public private(set) var frame: NSImage?
    @Published public private(set) var lastFrameAt: Date?
    @Published public private(set) var framePixelSize: CGSize = .zero
    @Published public private(set) var fingerprint: MirrorFrameFingerprint?
    @Published public private(set) var framesPerSecond: Double = 0
    @Published public private(set) var error: String?

    /// Pause between captures while the screen is changing.
    public static let activeInterval: TimeInterval = 0.04
    /// Pause once the screen has been still for `stillFramesBeforeIdle` captures.
    public static let idleInterval: TimeInterval = 1.0
    public static let stillFramesBeforeIdle = 5

    /// Snapshot-harness only: a process launched from a terminal never becomes the active app, so
    /// the background pause would keep the live view on "Connecting…" forever. The flag lifts that
    /// pause and nothing else; it does not change what is captured or add an input path.
    private static let capturesWhileInactive = CommandLine.arguments.contains("--force-mirror-capture")

    private let source: (any SimulatorFramebufferSource)?
    private var task: Task<Void, Never>?
    private var viewers = 0
    private var udid = ""
    private var wakeRequested = false
    private var stillFrames = 0
    /// Digest of the exact bytes on screen. Only a byte-identical capture is skipped, so a small real
    /// change can never be hidden behind a coarse fingerprint match.
    private var frameDigest: String?

    public init(source: (any SimulatorFramebufferSource)? = nil) {
        self.source = source
    }

    public var isStreaming: Bool { task != nil }
    /// True while the loop is in its slow, screen-is-still cadence.
    public var isIdlePolling: Bool { stillFrames >= Self.stillFramesBeforeIdle }

    /// Frees the last frame and clears any error, e.g. when the preview is turned off.
    public func reset() {
        frame = nil; lastFrameAt = nil; framePixelSize = .zero; fingerprint = nil
        framesPerSecond = 0; error = nil; stillFrames = 0; frameDigest = nil
    }

    /// A viewport appeared. Streaming starts with the first viewer and stops with the last.
    public func attach(udid: String) {
        viewers += 1
        self.udid = udid
        if task == nil { start() }
    }

    public func detach() {
        viewers = max(0, viewers - 1)
        if viewers == 0 { stop() }
    }

    /// Capture the next frame now instead of waiting out the current interval. Used when the device
    /// is known to have changed (an action finished, an observation arrived).
    public func requestImmediateFrame() {
        wakeRequested = true
        stillFrames = 0
    }

    /// Applies one capture result. Separated from the loop so the dedupe and back-off rules are testable.
    @discardableResult
    func accept(_ result: Result<FramebufferCapture, FramebufferCaptureError>, elapsed: TimeInterval) -> Bool {
        switch result {
        case .failure(let failure):
            error = failure.message
            framesPerSecond = 0
            return false
        case .success(let capture):
            // A @Published value publishes on every assignment, equal or not, and every view watching the mirror redraws. This runs about 25 times
            // a second, so only a real change is assigned.
            if error != nil { error = nil }
            let dt = max(elapsed, 0.001)
            let smoothed = framesPerSecond == 0 ? 1 / dt : framesPerSecond * 0.8 + (1 / dt) * 0.2
            if abs(smoothed - framesPerSecond) >= 0.5 { framesPerSecond = smoothed }
            // The picture is still refreshed in time (lastFrameAt) so staleness stays honest, but a
            // byte-identical frame is not decoded or published as a new image.
            if lastFrameAt != capture.capturedAt { lastFrameAt = capture.capturedAt }
            let digest = IntegrityHash.sha256Hex(capture.data)
            if frame != nil, digest == frameDigest {
                stillFrames += 1
                return false
            }
            let print = MirrorFrameFingerprint.make(fromEncoded: capture.data)
            // Visually still (below the change threshold) counts toward the slow cadence; it is still shown.
            if let print, let current = fingerprint, !print.differs(from: current) { stillFrames += 1 } else { stillFrames = 0 }
            guard let image = NSImage(data: capture.data) else { error = FramebufferCaptureError.unreadable.message; return false }
            frame = image
            frameDigest = digest
            framePixelSize = capture.pixelSize
            fingerprint = print
            return true
        }
    }

    private func start() {
        guard let source else {
            error = "No framebuffer source is configured for this window."
            return
        }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !(NSApp?.isActive ?? true) && !Self.capturesWhileInactive {
                    try? await Task.sleep(nanoseconds: 500_000_000); continue
                }
                let began = Date()
                let result = await source.captureFrame(udid: self.udid)
                self.accept(result, elapsed: Date().timeIntervalSince(began))
                if case .failure = result {
                    await self.pause(1.5)
                } else {
                    await self.pause(self.isIdlePolling ? Self.idleInterval : Self.activeInterval)
                }
            }
        }
    }

    /// Sleeps in short slices so `requestImmediateFrame` takes effect within ~40 ms.
    private func pause(_ seconds: TimeInterval) async {
        var remaining = seconds
        while remaining > 0, !Task.isCancelled {
            if wakeRequested { wakeRequested = false; return }
            let slice = min(remaining, 0.04)
            try? await Task.sleep(nanoseconds: UInt64(slice * 1_000_000_000))
            remaining -= slice
        }
    }

    private func stop() {
        task?.cancel()
        task = nil
        framesPerSecond = 0
        // Nobody is looking: the video stream behind the picture stops too, instead of running (and reading) for as long as the app is open.
        source?.stop()
    }
}
