import Foundation
import AgentCore

struct GenerationConfig: Codable, Sendable {
    let temperature: Double?

    init(temperature: Double? = nil) {
        self.temperature = temperature
    }
}

struct GenerateContentRequest: Codable, Sendable {
    let systemInstruction: Content?
    let contents: [Content]
    let generationConfig: GenerationConfig?

    init(systemInstruction: Content? = nil, contents: [Content], generationConfig: GenerationConfig? = nil) {
        self.systemInstruction = systemInstruction
        self.contents = contents
        self.generationConfig = generationConfig
    }
}

struct Content: Codable, Sendable {
    let role: String?
    let parts: [Part]

    init(role: String? = nil, parts: [Part]) {
        self.role = role
        self.parts = parts
    }
}

struct Part: Codable, Sendable {
    let text: String?
    let inlineData: InlineData?

    init(text: String? = nil, inlineData: InlineData? = nil) {
        self.text = text
        self.inlineData = inlineData
    }
}

/// An image sent inline with a request, base64 encoded.
struct InlineData: Codable, Sendable {
    let mimeType: String
    let data: String
}
