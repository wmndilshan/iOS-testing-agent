import Foundation

/// The words in a failing step worth looking for in the app's source: accessibility identifiers, type names, localized keys and the
/// visible labels the case mentions. Plain words ("tap", "verify") are left out, since they name the test, not the app.
enum CodeTerms {
    static let maximum = 8

    private static let separated = try! NSRegularExpression(pattern: #"[A-Za-z][A-Za-z0-9]*(?:[-_.][A-Za-z0-9]+)+"#)
    private static let camelCase = try! NSRegularExpression(pattern: #"\b[A-Z][a-z0-9]+(?:[A-Z][a-z0-9]+)+\b"#)
    private static let quoted = try! NSRegularExpression(pattern: #"['"‘“]([^'"’”\n]{3,40})['"’”]"#)
    private static let titleCase = try! NSRegularExpression(pattern: #"\b[A-Z][a-z]+(?: [A-Z][a-z]+)+\b"#)

    private static let ignored: Set<String> = ["expected", "step", "tap", "verify", "note", "launch", "wait", "then", "should", "button", "screen", "the", "and",
                                               "test data", "not found", "accessibility", "observation failed"]

    /// Terms in priority order: identifiers first (they match code exactly), then quoted labels, then capitalized phrases.
    static func extract(from texts: [String]) -> [String] {
        var found: [String] = []
        var seen = Set<String>()
        func add(_ term: String) {
            let clean = term.trimmingCharacters(in: CharacterSet(charactersIn: " .,:;()[]"))
            let key = clean.lowercased()
            guard clean.count >= 4, !ignored.contains(key), seen.insert(key).inserted else { return }
            found.append(clean)
        }
        for regex in [separated, camelCase, quoted, titleCase] {
            for text in texts {
                let range = NSRange(text.startIndex..., in: text)
                for match in regex.matches(in: text, range: range) {
                    let captured = match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range
                    if let r = Range(captured, in: text) { add(String(text[r])) }
                }
            }
        }
        return Array(found.prefix(maximum))
    }
}
