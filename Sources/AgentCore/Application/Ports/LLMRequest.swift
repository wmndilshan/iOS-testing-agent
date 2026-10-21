import Foundation

/// A provider-neutral request to a language model.
///
/// The application describes *what* it wants to ask; each provider adapter under `Infrastructure/LLM` translates that into its own wire format.
/// Nothing here names a provider.
public struct LLMRequest: Sendable {
    public let systemInstruction: String?
    public let messages: [LLMMessage]
    public let temperature: Double?

    public init(
        systemInstruction: String? = nil,
        messages: [LLMMessage],
        temperature: Double? = nil
    ) {
        self.systemInstruction = systemInstruction
        self.messages = messages
        self.temperature = temperature
    }
}

public struct LLMMessage: Sendable, Equatable {
    public enum Role: String, Sendable, Equatable {
        case user
        case model
    }

    public let role: Role
    public let text: String
    /// An optional PNG screenshot sent with the text (for vision models).
    public let imagePNG: Data?
    /// The encoding of `imagePNG` (the property keeps its name; a screenshot may be sent as a smaller JPEG).
    public let imageMIMEType: String

    public init(role: Role = .user, text: String, imagePNG: Data? = nil, imageMIMEType: String = "image/png") {
        self.role = role
        self.text = text
        self.imagePNG = imagePNG
        self.imageMIMEType = imageMIMEType
    }
}
