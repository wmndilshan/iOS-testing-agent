import Foundation
import Testing
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("Observation redaction")
struct ObservationRedactionTests {
    @Test func testSensitiveDataRedaction() {
        let secureEl = UIElementSnapshot(
            id: "p1",
            role: "secureTextField",
            label: "SuperSecretPassword123",
            identifier: "secret_pass",
            isSecure: true
        )

        let textEl = UIElementSnapshot(
            id: "p2",
            role: "textField",
            label: "user_secret_token_1234567890",
            identifier: "otp_code_123456789"
        )

        let sanitized = ObservationFilter.sanitize(elements: [secureEl, textEl])
        #expect(sanitized[0].label == "[REDACTED_SECURE]")
        #expect(sanitized[0].identifier == "[REDACTED_SECURE]")
        #expect(sanitized[1].label == "[REDACTED_SENSITIVE]")
        #expect(sanitized[1].identifier == "[REDACTED_SENSITIVE]")
    }

    @Test func testSensitiveFieldsRedaction() {
        let secureEl = UIElementSnapshot(
            id: "p_sec",
            role: "secureTextField",
            label: "SuperSecretPassword123",
            identifier: "secret_pass_field",
            value: "SecretPasswordValue",
            placeholderValue: "Enter Password Here",
            isSecure: true
        )
        let tokenEl = UIElementSnapshot(
            id: "p_tok",
            role: "textField",
            label: "user_secret_token_1234567890",
            identifier: "otp_code_123456789",
            value: "session_token_abcdef123456"
        )
        let cardEl = UIElementSnapshot(
            id: "p_card",
            role: "staticText",
            label: "credit_card_4111222233334444"
        )

        let sanitized = ObservationFilter.sanitize(elements: [secureEl, tokenEl, cardEl])

        #expect(sanitized[0].label == "[REDACTED_SECURE]")
        #expect(sanitized[0].identifier == "[REDACTED_SECURE]")
        #expect(sanitized[0].value == "[REDACTED_SECURE]")
        #expect(sanitized[0].placeholderValue == "[REDACTED_SECURE]")

        #expect(sanitized[1].label == "[REDACTED_SENSITIVE]")
        #expect(sanitized[1].identifier == "[REDACTED_SENSITIVE]")
        #expect(sanitized[1].value == "[REDACTED_SENSITIVE]")

        #expect(sanitized[2].label == "[REDACTED_SENSITIVE]")
    }
}
