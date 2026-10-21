import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation

/// A thread that reads for as long as the process lives never returns to a run loop, so nothing drains its autorelease pool: without a pool
/// per read, every chunk it reads stays allocated. The live view did this at about 1 MB a second until the app stalled at many gigabytes.
@Suite("Long-lived reader threads")
struct ReaderThreadTests {
    @Test("Every file that starts a reader thread drains a pool per read")
    func poolPerRead() {
        for file in SourceTree.all where file.code.contains("Thread.detachNewThread") {
            #expect(file.code.contains("autoreleasepool"), "\(file.path) starts a thread that reads for the life of the process and must use autoreleasepool in its loop")
        }
    }

    private func frame(_ fill: UInt8, count: Int = 50) -> Data { Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: fill, count: count) }

    @Test("A stream is cut into whole frames, whatever the chunk sizes, and the last one waits for its end")
    func splitting() {
        let stream = frame(1) + frame(2) + frame(3)
        var splitter = JPEGFrameSplitter()
        var frames: [Data] = []
        var index = stream.startIndex
        while index < stream.endIndex {
            let end = stream.index(index, offsetBy: 7, limitedBy: stream.endIndex) ?? stream.endIndex
            frames += splitter.append(stream[index..<end])
            index = end
        }
        #expect(frames == [frame(1), frame(2)])
        #expect(splitter.pendingByteCount == frame(3).count)
        #expect(splitter.append(frame(4)) == [frame(3)])
    }

    @Test("Bytes that never show a frame marker are dropped at the limit instead of growing")
    func bounded() {
        var splitter = JPEGFrameSplitter()
        let junk = Data(repeating: 0x41, count: 1_000_000)
        for _ in 0..<12 { _ = splitter.append(junk) }
        #expect(splitter.pendingByteCount <= JPEGFrameSplitter.limit)
    }

    @Test("Leaving the live view stops the stream behind it")
    @MainActor func stopsTheSource() async {
        final class Source: SimulatorFramebufferSource, @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            var stops: Int { lock.withLock { count } }
            func captureFrame(udid: String) async -> Result<FramebufferCapture, FramebufferCaptureError> { .failure(.deviceShutDown) }
            func stop() { lock.withLock { count += 1 } }
        }
        let source = Source()
        let mirror = SimulatorMirror(source: source)
        mirror.attach(udid: "710E5B5D-C7CF-4CC7-8A56-CA363D1565BA")
        mirror.attach(udid: "710E5B5D-C7CF-4CC7-8A56-CA363D1565BA")
        mirror.detach()
        #expect(source.stops == 0, "one viewer is still looking")
        mirror.detach()
        #expect(source.stops == 1)
    }
}
