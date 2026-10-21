import Foundation

public struct ToolCall: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let arguments: [String: AnyCodableValue]

    public init(id: String, name: String, arguments: [String: AnyCodableValue]) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

// MARK: - ToolResult DTO
