import Foundation
import ImageIO
import AgentCore

/// `SimulatorFramebufferSource` over `xcrun simctl io <udid> screenshot`.
///
/// The argument vector is fixed apart from a validated UDID and a private temp path, and it is
/// passed as an array, never through a shell. The only simctl verb it can issue is `io … screenshot`:
/// it reads pixels and cannot send input, boot, install or launch anything.
public struct SimctlFramebufferCapture: SimulatorFramebufferSource {
    public init() {}

    public func captureFrame(udid: String) async -> Result<FramebufferCapture, FramebufferCaptureError> {
        guard udid.range(of: #"^[0-9A-Fa-f\-]{36}$"#, options: .regularExpression) != nil else { return .failure(.invalidDevice) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("atagent-frame-\(UUID().uuidString).jpg")
        return await Task.detached(priority: .utility) { () -> Result<FramebufferCapture, FramebufferCaptureError> in
            defer { try? FileManager.default.removeItem(at: url) }
            let process = Process()
            process.executableURL = Toolchain.xcrun
            process.arguments = ["simctl", "io", udid, "screenshot", "--type=jpeg", url.path]
            process.standardOutput = Pipe()
            let stderr = Pipe()
            process.standardError = stderr
            do { try process.run() } catch { return .failure(.toolFailed("Could not run simctl: \(error.localizedDescription)")) }
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let capturedAt = Date()
            guard process.terminationStatus == 0 else {
                let text = String(data: errData, encoding: .utf8) ?? ""
                if text.contains("Unable to lookup in current state: Shutdown") || text.contains("not booted") {
                    return .failure(.deviceShutDown)
                }
                return .failure(.toolFailed(text.split(separator: "\n").last.map(String.init) ?? "simctl exited with \(process.terminationStatus)"))
            }
            guard let data = try? Data(contentsOf: url), let size = Self.pixelSize(of: data) else { return .failure(.unreadable) }
            return .success(FramebufferCapture(data: data, pixelSize: size, capturedAt: capturedAt))
        }.value
    }

    static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }
}
