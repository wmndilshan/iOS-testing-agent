import Foundation

public struct ObservationFilter: Sendable {
    /// Hybrid UIKit/WebView accessibility trees can place meaningful controls at twelve wrapper
    /// levels. The finite bound retains those controls while avoiding unbounded traversal of
    /// zero-frame WebView implementation nodes beneath the semantic accessibility endpoints.
    public static let defaultMaxDepth = 12
    public static let defaultMaxElements = 250

    /// Sanitizes and bounds an element tree, removing sensitive data and enforcing limits.
    public static func sanitize(
        elements: [UIElementSnapshot],
        maxDepth: Int = defaultMaxDepth,
        maxElements: Int = defaultMaxElements
    ) -> [UIElementSnapshot] {
        return sanitizeWithTruncation(elements: elements, maxDepth: maxDepth, maxElements: maxElements).elements
    }

    /// Sanitizes and bounds an element tree, returning both sanitized elements and truncation status.
    public static func sanitizeWithTruncation(
        elements: [UIElementSnapshot],
        maxDepth: Int = defaultMaxDepth,
        maxElements: Int = defaultMaxElements
    ) -> (elements: [UIElementSnapshot], isTruncated: Bool) {
        var sanitized: [UIElementSnapshot] = []
        var isTruncated = false

        for element in elements {
            // Depth limit
            if element.depth > maxDepth {
                isTruncated = true
                continue
            }

            // Element count limit
            if sanitized.count >= maxElements {
                isTruncated = true
                break
            }

            // Redaction of sensitive values
            let redactedLabel = redactSensitiveText(element.label, isSecure: element.isSecure)
            let redactedIdentifier = redactSensitiveText(element.identifier, isSecure: element.isSecure)
            let redactedValue = redactSensitiveText(element.value, isSecure: element.isSecure)
            let redactedPlaceholder = redactSensitiveText(element.placeholderValue, isSecure: element.isSecure)

            let cleanElement = UIElementSnapshot(
                id: element.id,
                parentID: element.parentID,
                role: element.role,
                label: redactedLabel,
                identifier: redactedIdentifier,
                value: redactedValue,
                placeholderValue: redactedPlaceholder,
                isEnabled: element.isEnabled,
                isHittable: element.isHittable,
                isSelected: element.isSelected,
                hasFocus: element.hasFocus,
                isSecure: element.isSecure,
                depth: element.depth,
                frame: element.frame
            )
            sanitized.append(cleanElement)
        }

        if elements.count > sanitized.count {
            isTruncated = true
        }

        return (sanitized, isTruncated)
    }

    /// Redacts known sensitive patterns (passwords, tokens, OTPs, PINs, cards, accounts).
    public static func redactSensitiveText(_ text: String?, isSecure: Bool) -> String? {
        guard let text = text, !text.isEmpty else { return nil }
        if isSecure {
            return "[REDACTED_SECURE]"
        }

        let lower = text.lowercased()
        let sensitiveKeywords = ["password", "secret", "token", "otp", "pin", "cvv", "ssn", "account", "card", "passcode"]
        for kw in sensitiveKeywords {
            if lower.contains(kw) && text.count > 10 {
                return "[REDACTED_SENSITIVE]"
            }
        }

        return text
    }
}
