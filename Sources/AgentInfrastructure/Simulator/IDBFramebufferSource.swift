import Foundation
import AgentCore

/// `SimulatorFramebufferSource` over `idb video-stream --format mjpeg`.
///
/// One long-lived stream per simulator keeps the newest frame; `captureFrame` returns it, so a viewer that polls gets about
/// eight frames a second instead of paying for a process per picture. Read-only like the other framebuffer sources: the only
/// idb verb it can issue is `video-stream`. Arguments are an array, never a shell string, and the UDID is validated.
public final class IDBFramebufferSource: SimulatorFramebufferSource, @unchecked Sendable {
    private let executable: URL
    private let framesPerSecond: Int
    private let lock = NSLock()
    private var latest: FramebufferCapture?
    private var process: Process?
    private var streamingUDID: String?

    /// A frame older than this means the stream has stalled.
    private static let staleAfter: TimeInterval = 3

    public init(executable: URL, framesPerSecond: Int = 8) {
        self.executable = executable
        self.framesPerSecond = framesPerSecond
    }

    /// The idb install the stream would use, or nil when idb is not installed.
    public static func locate(projectRoot: URL) -> URL? { IDBClient.locate(projectRoot: projectRoot) }

    public func captureFrame(udid: String) async -> Result<FramebufferCapture, FramebufferCaptureError> {
        guard udid.range(of: #"^[0-9A-Fa-f\-]{36}$"#, options: .regularExpression) != nil else { return .failure(.invalidDevice) }
        if let failure = ensureStreaming(udid) { return .failure(failure) }
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if let frame = currentFrame(), Date().timeIntervalSince(frame.capturedAt) < Self.staleAfter { return .success(frame) }
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        stop()
        return .failure(.toolFailed("The idb video stream produced no frame. Is the simulator booted and idb_companion installed?"))
    }

    public func stop() {
        lock.lock()
        let running = process
        process = nil
        streamingUDID = nil
        latest = nil
        lock.unlock()
        if running?.isRunning == true { running?.terminate() }
    }

    deinit { stop() }

    private func currentFrame() -> FramebufferCapture? { lock.withLock { latest } }

    private func ensureStreaming(_ udid: String) -> FramebufferCaptureError? {
        lock.lock()
        defer { lock.unlock() }
        if let process, process.isRunning, streamingUDID == udid { return nil }
        if process?.isRunning == true { process?.terminate() }
        latest = nil
        let task = Process()
        task.executableURL = executable
        task.arguments = ["video-stream", "--udid", udid, "--format", "mjpeg", "--fps", String(framesPerSecond), "--compression-quality", "0.7"]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return .toolFailed("Could not start idb: \(error.localizedDescription)") }
        process = task
        streamingUDID = udid
        let handle = output.fileHandleForReading
        Thread.detachNewThread { [weak self] in Self.read(handle, into: self) }
        return nil
    }

    /// Splits the stream into frames at each JPEG start marker (`FF D8 FF`) and keeps the newest complete one.
    private static func read(_ handle: FileHandle, into source: IDBFramebufferSource?) {
        var splitter = JPEGFrameSplitter()
        var finished = false
        while !finished {
            // This thread never returns to a run loop, so nothing drains its autorelease pool: every 16 KB chunk read from the pipe would be kept
            // for as long as the thread lives (about 1 MB a second at eight frames a second, until the app stalls). One pool per read frees them.
            autoreleasepool {
                let chunk = handle.availableData
                if chunk.isEmpty { finished = true; return }
                for frame in splitter.append(chunk) {
                    if let size = SimctlFramebufferCapture.pixelSize(of: frame), let source {
                        source.lock.withLock { source.latest = FramebufferCapture(data: frame, pixelSize: size, capturedAt: Date()) }
                    }
                }
            }
        }
    }
}

/// Cuts a stream of JPEG images into single images at each start marker (`FF D8 FF`). The last, still incomplete image stays buffered.
struct JPEGFrameSplitter {
    private var buffer = Data()
    private let marker: [UInt8] = [0xFF, 0xD8, 0xFF]
    /// A stream that never shows a marker is not a video; the buffer is dropped rather than grown without limit.
    static let limit = 8_000_000

    /// The complete frames the new bytes finish.
    mutating func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var frames: [Data] = []
        while let next = nextMarker(from: 3) {
            frames.append(Data(buffer.prefix(next)))
            buffer.removeSubrange(0..<next)
        }
        if buffer.count > Self.limit { buffer.removeAll() }
        return frames
    }

    var pendingByteCount: Int { buffer.count }

    /// Looks at the bytes where they are; copying the whole buffer into an array for every search is what this replaces.
    private func nextMarker(from start: Int) -> Int? {
        buffer.withUnsafeBytes { raw -> Int? in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard bytes.count >= start + marker.count else { return nil }
            var i = start
            while i <= bytes.count - marker.count {
                if bytes[i] == marker[0], bytes[i + 1] == marker[1], bytes[i + 2] == marker[2] { return i }
                i += 1
            }
            return nil
        }
    }
}
