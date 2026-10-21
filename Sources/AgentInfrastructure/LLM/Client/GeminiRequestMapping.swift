import Foundation
import AgentCore

/// Translation between the provider-neutral application types and Gemini's wire format.
/// This is the only place that knows both vocabularies.
extension LLMRequest {
    /// Gemini wire body for this request. System instruction and temperature are sent only when set.
    var geminiGenerateContentRequest: GenerateContentRequest {
        let instruction = systemInstruction.flatMap { text -> Content? in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : Content(parts: [Part(text: trimmed)])
        }
        return GenerateContentRequest(
            systemInstruction: instruction,
            contents: geminiContents,
            generationConfig: temperature.map { GenerationConfig(temperature: $0) }
        )
    }

    var geminiContents: [Content] {
        messages.map { message in
            // The image goes first, then the text that refers to it.
            let image = message.imagePNG.map { Part(inlineData: InlineData(mimeType: message.imageMIMEType, data: $0.base64EncodedString())) }
            return Content(role: message.role.rawValue, parts: (image.map { [$0] } ?? []) + [Part(text: message.text)])
        }
    }
}
