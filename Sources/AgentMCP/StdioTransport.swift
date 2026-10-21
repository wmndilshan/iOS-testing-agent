import Foundation
import AgentGateway

/// Newline-delimited JSON over standard input and output, the MCP stdio transport. Standard output carries protocol messages only; anything for a
/// person goes to standard error.
public enum StdioTransport {
    /// Reads messages until the client closes standard input. Each is handed to `server.receive`; replies are written as one line each.
    public static func run(gateway: Gateway, info: MCPServerInfo) async {
        let writer = LineWriter()
        let server = MCPServer(gateway: gateway, info: info) { writer.write($0) }
        for await line in lines(from: FileHandle.standardInput) {
            guard !line.isEmpty else { continue }
            await server.receive(line)
        }
    }

    /// Complete lines of a file handle, as they arrive.
    static func lines(from handle: FileHandle) -> AsyncStream<Data> {
        AsyncStream { continuation in
            Thread.detachNewThread {
                var pending = Data()
                var finished = false
                while !finished {
                    // A pool per read, as for every thread that reads for as long as the process lives (see IDBFramebufferSource).
                    autoreleasepool {
                        let chunk = handle.availableData
                        if chunk.isEmpty { finished = true; return }
                        pending.append(chunk)
                        while let newline = pending.firstIndex(of: 0x0A) {
                            continuation.yield(Data(pending[pending.startIndex..<newline]))
                            pending.removeSubrange(pending.startIndex...newline)
                        }
                    }
                }
                if !pending.isEmpty { continuation.yield(pending) }
                continuation.finish()
            }
        }
    }
}

/// Writes one message per line to standard output; a lock keeps concurrent replies from interleaving.
final class LineWriter: @unchecked Sendable {
    private let lock = NSLock()

    func write(_ message: Data) {
        lock.withLock {
            FileHandle.standardOutput.write(message + Data([0x0A]))
        }
    }
}
