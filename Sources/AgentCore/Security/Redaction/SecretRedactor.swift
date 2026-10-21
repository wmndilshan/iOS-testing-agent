import Foundation

/// Central, deterministic redaction for anything that leaves the trusted process boundary as text:
/// run traces, timeline detail panes, run history, reports and diagnostics.
///
/// It masks credential *values* (API keys, bearer/JWT tokens, `password=...` style assignments)
/// while deliberately leaving identifiers that are not authentication secrets — such as the UUID of
/// a single-use approval token — readable, because those are required for audit correlation.
public enum SecretRedactor {

    public static let redactionMarker = "[REDACTED]"

    private static let patterns: [(regex: String, replacement: String)] = [
        // Google / Gemini API keys.
        ("AIza[0-9A-Za-z_\\-]{20,}", "[REDACTED_API_KEY]"),
        // JSON Web Tokens.
        ("eyJ[A-Za-z0-9_\\-]{5,}\\.[A-Za-z0-9_\\-]{5,}\\.[A-Za-z0-9_\\-]{5,}", "[REDACTED_JWT]"),
        // Authorization: Bearer <value>
        ("(?i)bearer\\s+[A-Za-z0-9\\-._~+/]{8,}=*", "Bearer [REDACTED]"),
        // key=value / key: value assignments for credential-looking keys (value only is masked).
        ("(?i)\\b(password|passwd|pwd|secret|api[_-]?key|access[_-]?token|refresh[_-]?token|auth[_-]?token|session[_-]?token|authorization)\\b(\\s*[:=]\\s*)(?!\\[REDACTED)(\"[^\"]*\"|'[^']*'|[^\\s,;}\\]]+)", "$1$2[REDACTED]")
    ]

    /// Returns `text` with credential values masked. Idempotent.
    public static func redact(_ text: String) -> String {
        var clean = text
        for (regex, replacement) in patterns {
            clean = clean.replacingOccurrences(of: regex, with: replacement, options: .regularExpression)
        }
        return clean
    }

    /// True when `text` still contains something that looks like a credential value.
    public static func containsSecret(_ text: String) -> Bool {
        redact(text) != text
    }

    /// Redacts an optional string.
    public static func redact(_ text: String?) -> String? {
        text.map { redact($0) }
    }
}
