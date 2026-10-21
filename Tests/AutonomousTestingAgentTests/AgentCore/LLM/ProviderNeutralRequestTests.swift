import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("Provider-neutral LLM request boundary")
struct ProviderNeutralRequestTests {

    @Test func testMessagesMapToGeminiContents() {
        let request = LLMRequest(messages: [LLMMessage(role: .user, text: "hi"), LLMMessage(role: .model, text: "yo")])
        let contents = request.geminiContents
        #expect(contents.map(\.role) == ["user", "model"])
        #expect(contents.map { $0.parts.first?.text } == ["hi", "yo"])
    }

    @Test func testImageGoesBeforeTheTextItRefersTo() {
        let request = LLMRequest(messages: [LLMMessage(text: "what is this", imagePNG: Data([1, 2, 3]), imageMIMEType: "image/jpeg")])
        let parts = request.geminiContents[0].parts
        #expect(parts.count == 2 && parts[0].inlineData?.mimeType == "image/jpeg" && parts[1].text == "what is this")
    }

    @Test func testProviderErrorsClassifyThroughTheNeutralProtocol() {
        #expect(LLMFailureKind.classify(LLMNetworkError.rateLimited(statusCode: 429, retryAfter: nil, message: "slow down")) == .rateLimited)
        #expect(LLMFailureKind.classify(LLMError.emptyResponse) == .emptyResponse)
    }
}
