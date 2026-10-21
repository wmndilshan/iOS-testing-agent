import Foundation

/// The one redaction policy for log events. Destinations never see unredacted events.
///
/// Three layers, all deterministic and idempotent:
/// 1. **By key**: a field whose name marks it as a credential (`password`, `apiKey`, `token`,
///    `authorization`, `cookie`, `username`, ...) is replaced wholesale, whatever its value looks like.
/// 2. **By value**: any string is scrubbed with `SecretRedactor` plus log-specific patterns (`.env`
///    style `NAME_KEY=value` lines, secret query parameters in URLs, `Cookie:` headers).
/// 3. **By size**: long strings are truncated, so a screenshot, a response body or a prompt cannot
///    end up in a log by accident.
///
/// Turning on debug logging never disables any of this.
public struct LogRedactor: Sendable {

    public static let marker = SecretRedactor.redactionMarker
    public static let maxStringLength = 500

    private static let sensitiveKeyFragments: [String] = [
        "password", "passwd", "passcode", "secret", "apikey", "privatekey", "token", "authorization",
        "cookie", "credential", "username", "typedtext", "signature", "bearer",
    ]

    private static let extraPatterns: [(regex: String, replacement: String)] = [
        // .env / shell style assignments: LLM_API_KEY=abc, DB_PASSWORD=abc, GITHUB_TOKEN=abc
        (#"(?i)\b([A-Z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD)[A-Z0-9_]*)(\s*=\s*)(?!\[REDACTED)("[^"]*"|'[^']*'|[^\s,;&]+)"#, "$1$2[REDACTED]"),
        // Secret query parameters in URLs (signed URLs, api keys in query strings).
        (#"(?i)([?&](?:key|api_key|apikey|token|access_token|refresh_token|signature|sig|x-amz-signature|x-goog-signature|auth)=)(?!\[REDACTED)[^&\s"']+"#, "$1[REDACTED]"),
        // Cookie headers.
        (#"(?i)\b(set-cookie|cookie)(\s*:\s*)(?!\[REDACTED)[^\n]+"#, "$1$2[REDACTED]"),
    ]

    public init() {}

    public func redact(_ event: LogEvent) -> LogEvent {
        var e = event
        e.message = LogText.sanitize(scrub(event.message))
        e.fields = event.fields.reduce(into: [:]) { acc, pair in
            acc[pair.key] = redact(pair.value, forKey: pair.key)
        }
        return e
    }

    public func redact(_ value: LogValue, forKey key: String) -> LogValue {
        if isSensitive(key: key) { return .string(Self.marker) }
        switch value {
        case .string(let s): return .string(scrubAndBound(s))
        case .array(let items): return .array(items.map { redact($0, forKey: key) })
        case .object(let dict): return .object(dict.reduce(into: [:]) { $0[$1.key] = redact($1.value, forKey: $1.key) })
        case .int, .double, .bool: return value
        }
    }

    public func isSensitive(key: String) -> Bool {
        let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
        return Self.sensitiveKeyFragments.contains { normalized.contains($0) }
    }

    /// Scrubs credential-looking values from free text.
    public func scrub(_ text: String) -> String {
        var clean = SecretRedactor.redact(text)
        for (regex, replacement) in Self.extraPatterns {
            clean = clean.replacingOccurrences(of: regex, with: replacement, options: .regularExpression)
        }
        return clean
    }

    private func scrubAndBound(_ text: String) -> String {
        let clean = scrub(text)
        guard clean.count > Self.maxStringLength else { return clean }
        return String(clean.prefix(Self.maxStringLength)) + "[TRUNCATED \(clean.count - Self.maxStringLength) chars]"
    }
}
