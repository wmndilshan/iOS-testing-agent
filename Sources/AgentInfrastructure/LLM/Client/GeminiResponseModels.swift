import Foundation
import AgentCore

struct UsageMetadata: Codable, Sendable, Equatable {
    let promptTokenCount: Int?
    let candidatesTokenCount: Int?
    let totalTokenCount: Int?
}

struct GenerateContentResponse: Codable, Sendable {
    let candidates: [Candidate]?
    let error: APIErrorPayload?
    let usageMetadata: UsageMetadata?
}

struct Candidate: Codable, Sendable {
    let content: Content?

    var text: String? {
        guard let parts = content?.parts else { return nil }
        let textParts = parts.compactMap { $0.text }
        return textParts.isEmpty ? nil : textParts.joined(separator: "\n")
    }
}

struct APIErrorPayload: Codable, Sendable {
    let code: Int?
    let message: String?
    let status: String?
}
