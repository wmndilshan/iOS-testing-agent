import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("38. Sensitive-Data Redaction Tests")
struct SecretRedactionTests {

    @Test("API keys, bearer tokens and JWTs are masked")
    func testCredentialShapesMasked() {
        let key = "AIzaSyD-1234567890abcdefghijklmnopqrstuv"
        #expect(!SecretRedactor.redact("key is \(key) ok").contains(key))
        #expect(!SecretRedactor.redact("Authorization: Bearer abcdef1234567890xyz").contains("abcdef1234567890xyz"))
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghijklmnop"
        #expect(!SecretRedactor.redact("t=\(jwt)").contains(jwt))
    }

    @Test("password / secret / api key assignments lose their value but keep the key")
    func testAssignmentsMasked() {
        let out = SecretRedactor.redact("password=hunter2 secret: topsecret api_key=abc123")
        #expect(!out.contains("hunter2"))
        #expect(!out.contains("topsecret"))
        #expect(!out.contains("abc123"))
        #expect(out.lowercased().contains("password"))
    }

    @Test("Approval token UUIDs (audit identifiers) stay readable")
    func testTokenIDsNotMasked() {
        let id = UUID().uuidString
        #expect(SecretRedactor.redact("Token ID: \(id)").contains(id))
    }

    @Test("Redaction is idempotent and ordinary text is untouched")
    func testIdempotent() {
        let text = "Tap the modal close button to dismiss the language sheet."
        #expect(SecretRedactor.redact(text) == text)
        let once = SecretRedactor.redact("password=abc")
        #expect(SecretRedactor.redact(once) == once)
        #expect(SecretRedactor.containsSecret("password=abc"))
        #expect(!SecretRedactor.containsSecret(text))
    }

    @Test("RunTrace never stores credentials, even if a caller tries to")
    func testTraceRedacts() {
        var trace = RunTrace(scenarioID: "S")
        trace.append(eventType: .observed, result: "login with password=hunter2 and key AIzaSyD-1234567890abcdefghijklmnopqrstuv")
        let encoded = String(data: (try? JSONEncoder().encode(trace)) ?? Data(), encoding: .utf8) ?? ""
        #expect(!encoded.contains("hunter2"))
        #expect(!encoded.contains("AIzaSyD"))
    }


    @Test("Run history records are redacted at construction")
    func testHistoryRedacted() {
        let record = RunHistoryRecord(runID: "r", date: Date(), scenarioID: "S", appBundleID: nil, executionMode: nil,
                                      result: "FAILED password=abc", durationSeconds: 1, stepCount: 0, recoveryCount: 0, healingCount: 0,
                                      skillsReused: [], skillsCreated: [], verificationResult: "bearer abcdefghijklmnop", humanApproved: false)
        #expect(!record.result.contains("abc "))
        #expect(!record.verificationResult.contains("abcdefghijklmnop"))
    }
}

