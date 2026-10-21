import Foundation

/// What a device command returned, as text an agent can read. A file the command produced (a screenshot) is named by its path.
public struct DeviceCommandResult: Codable, Sendable, Equatable {
    public let ok: Bool
    public let text: String
    public let filePath: String?
    /// Where a tap, press or swipe landed, in device points. Lets the live view show what the agent just touched.
    public let pointX: Double?
    public let pointY: Double?

    public init(ok: Bool = true, text: String, filePath: String? = nil, pointX: Double? = nil, pointY: Double? = nil) {
        self.ok = ok
        self.text = text
        self.filePath = filePath
        self.pointX = pointX
        self.pointY = pointY
    }
}
