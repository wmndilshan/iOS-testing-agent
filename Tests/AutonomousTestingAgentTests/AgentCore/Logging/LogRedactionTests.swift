import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("Log redaction")
struct LogRedactionTests {
    private let redactor = LogRedactor()
    private let apiKey = "AIzaSyD-1234567890abcdefghijklmnop"

    private func event(_ message: String = "", fields: [String: LogValue] = [:]) -> LogEvent {
        LogEvent(level: .info, category: .llm, event: "llm.request.started", message: message, fields: fields)
    }

    @Test func testAPIKeysAreRedactedInMessagesAndFields() {
        let e = redactor.redact(event("using key \(apiKey) now", fields: ["note": .string("key=\(apiKey)")]))
        #expect(!e.message.contains(apiKey))
        if case .string(let s)? = e.fields["note"] { #expect(!s.contains(apiKey)) } else { Issue.record("missing field") }
    }

    @Test func testCredentialFieldsAreRedactedByNameRegardlessOfValue() {
        let e = redactor.redact(event(fields: [
            "password": "hunter2", "userName": "alice", "apiKey": "x", "access_token": "t", "Authorization": "Bearer abc.def.ghi",
            "cookie": "sid=1", "credentials": .object(["a": "b"]), "typedText": "s3cret", "elementID": "elem_1", "attempt": 2,
        ]))
        for key in ["password", "userName", "apiKey", "access_token", "Authorization", "cookie", "credentials", "typedText"] {
            #expect(e.fields[key] == .string(LogRedactor.marker), "\(key) must be redacted")
        }
        #expect(e.fields["elementID"] == "elem_1", "non-sensitive fields are untouched")
        #expect(e.fields["attempt"] == 2)
    }

    @Test func testAuthorizationHeadersAndBearerTokensAreRedactedInText() {
        let text = redactor.scrub("Authorization: Bearer abcdef1234567890 and x-goog-api-key: \(apiKey)")
        #expect(!text.contains("abcdef1234567890") && !text.contains(apiKey))
    }

    @Test func testEnvFileStyleLinesAndSignedURLsAreRedacted() {
        let env = redactor.scrub("LLM_API_KEY=supersecretvalue\nGITHUB_TOKEN=ghp_abcdef\nMODEL=gemini")
        #expect(!env.contains("supersecretvalue") && !env.contains("ghp_abcdef"))
        #expect(env.contains("MODEL=gemini"))
        let url = redactor.scrub("https://x.test/file?id=7&X-Amz-Signature=deadbeef&token=abc123&key=zzz")
        #expect(!url.contains("deadbeef") && !url.contains("abc123") && !url.contains("zzz"))
        #expect(url.contains("id=7"))
        #expect(!redactor.scrub("Cookie: session=abcdef; theme=dark").contains("abcdef"))
    }

    @Test func testNestedStructuresAreRedactedRecursively() {
        let e = redactor.redact(event(fields: [
            "request": .object(["headers": .object(["Authorization": "Bearer zzzzzzzzzz"]), "url": .string("https://x.test?token=t0k3n"), "count": 3]),
            "items": .array([.string("password=abc"), .object(["secret": "s"])]),
        ]))
        guard case .object(let req)? = e.fields["request"], case .object(let headers)? = req["headers"] else { Issue.record("shape"); return }
        #expect(headers["Authorization"] == .string(LogRedactor.marker))
        if case .string(let u)? = req["url"] { #expect(!u.contains("t0k3n")) }
        #expect(req["count"] == 3)
        guard case .array(let items)? = e.fields["items"] else { Issue.record("shape"); return }
        if case .string(let s) = items[0] { #expect(!s.contains("password=abc")) }
        if case .object(let o) = items[1] { #expect(o["secret"] == .string(LogRedactor.marker)) }
    }

    @Test func testRedactionIsIdempotent() {
        let once = redactor.redact(event("key \(apiKey) password=abc", fields: ["password": "p", "u": .string("https://x?token=abc"), "n": 1]))
        let twice = redactor.redact(once)
        #expect(once == twice)
    }

    @Test func testHugeValuesAreTruncatedSoPayloadsCannotBeLogged() {
        let e = redactor.redact(event(fields: ["screenshot": .string(String(repeating: "A", count: 100_000))]))
        if case .string(let s)? = e.fields["screenshot"] {
            #expect(s.count < LogRedactor.maxStringLength + 40)
            #expect(s.contains("TRUNCATED"))
        } else { Issue.record("missing") }
    }

    @Test func testDebugLevelNeverDisablesRedaction() {
        let sink = InMemoryLogDestination()
        let logger = DestinationLogger(minimumLevel: .trace, destinations: [sink])
        logger.log(.trace, .security, "security.probe.checked", "key \(apiKey)", fields: ["password": "p", "token": "t"])
        let stored = sink.events.first!
        #expect(!stored.message.contains(apiKey))
        #expect(stored.fields["password"] == .string(LogRedactor.marker) && stored.fields["token"] == .string(LogRedactor.marker))
    }
}
