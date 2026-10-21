import Foundation

/// A compact, deterministic, descriptive-only summary of what the trusted observation layer
/// actually saw. This is the ONLY authoritative source of truth for "what elements exist" that an LLM-
/// generated `TestIR` is ever grounded against (`ObservationGroundingService`). It carries no execution
/// authority of its own — it is data, derived purely from `Observation`, never constructed by an LLM or by
/// anything upstream of a real (or, in tests, explicitly simulated) capture.
public struct ObservedElementState: Codable, Sendable, Equatable {
    public let isEnabled: Bool
    public let isHittable: Bool
    public let isSelected: Bool?

    public init(isEnabled: Bool, isHittable: Bool, isSelected: Bool?) {
        self.isEnabled = isEnabled
        self.isHittable = isHittable
        self.isSelected = isSelected
    }
}

/// One observed element, reduced to exactly the fields a grounding decision or an LLM prompt ever needs.
/// Deliberately excludes `frame`/`depth`/`value`/`placeholderValue`/`hasFocus`/`isSecure`: geometry is
/// never sent to an LLM (no coordinate vocabulary to invent from), and secure/value fields are content, not
/// identity — grounding only needs to know an element's role/identifier/label, never what it currently
/// contains.
public struct ObservedElementReference: Codable, Sendable, Equatable {
    public let elementID: String
    public let accessibilityIdentifier: String?
    public let label: String?
    public let role: String
    public let state: ObservedElementState

    public init(elementID: String, accessibilityIdentifier: String?, label: String?, role: String, state: ObservedElementState) {
        self.elementID = elementID
        self.accessibilityIdentifier = accessibilityIdentifier
        self.label = label
        self.role = role
        self.state = state
    }
}

/// The authoritative UI vocabulary for exactly one snapshot. Binding to `snapshotID` is what lets a
/// grounding result (or an LLM prompt) be proven current or stale later — see
/// `ObservationGroundingService.isCurrent(_:against:)`.
public struct ObservedUIVocabulary: Codable, Sendable, Equatable {
    public let snapshotID: String
    public let bundleID: String
    public let elements: [ObservedElementReference]

    public init(snapshotID: String, bundleID: String, elements: [ObservedElementReference]) {
        self.snapshotID = snapshotID
        self.bundleID = bundleID
        self.elements = elements
    }

    /// The only constructor a caller should use in practice: derives the vocabulary purely from a real (or
    /// simulated) `Observation`, through the same sanitization/redaction (`ObservationFilter`) already
    /// trusted elsewhere in this pipeline — never a second, parallel sanitization policy.
    public static func derive(from observation: Observation) -> ObservedUIVocabulary {
        let sanitized = ObservationFilter.sanitize(elements: observation.elements)
        let refs = sanitized.map { element in
            ObservedElementReference(
                elementID: element.id,
                accessibilityIdentifier: ObservationFilter.redactSensitiveText(element.identifier, isSecure: element.isSecure),
                label: ObservationFilter.redactSensitiveText(element.label, isSecure: element.isSecure),
                role: element.role,
                state: ObservedElementState(isEnabled: element.isEnabled, isHittable: element.isHittable, isSelected: element.isSelected)
            )
        }
        return ObservedUIVocabulary(snapshotID: observation.snapshotID, bundleID: observation.bundleID, elements: refs)
    }

    /// A deterministic, versioned, compact rendering for an LLM prompt. Stable field
    /// order and formatting so the exact prompt text is reproducible and diffable across runs — never
    /// built ad hoc at each call site.
    public static let promptFormatVersion = "2"

    /// Labels are matched exactly, so a label is listed whole or not at all: anything longer than this is paragraph text, not a target.
    private static let maxLabelLength = 120
    /// At most this many elements are listed: on-screen ones first, then off-screen ones, so a long page cannot bury the controls.
    private static let maxListed = 170

    public func promptBlock() -> String {
        // One line per element, `role | id | label`, with `-` for none. Elements that repeat the same role, id and label (web pages
        // list many twice) appear once. Controls that are on screen come before everything else.
        var seen = Set<String>()
        var visible: [String] = [], other: [String] = []
        for element in elements {
            let label = element.label.map { $0.replacingOccurrences(of: "\n", with: " ") } ?? "-"
            if label.count > Self.maxLabelLength { continue }
            let id = element.accessibilityIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? "-"
            if id == "-" && label == "-" { continue }
            guard seen.insert("\(element.role)|\(id)|\(label)").inserted else { continue }
            var line = "\(element.role) | \(id) | \(label)"
            if !element.state.isEnabled { line += " [disabled]" }
            if let selected = element.state.isSelected { line += selected ? " [selected]" : "" }
            if element.state.isHittable { visible.append(line) } else { other.append(line + " [offscreen]") }
        }
        var lines = ["CURRENT OBSERVED UI (format v\(Self.promptFormatVersion), snapshot \(snapshotID)). One element per line: role | identifier | label. A dash means none. Copy identifiers and labels exactly."]
        lines += Array((visible + other).prefix(Self.maxListed))
        let omitted = visible.count + other.count - min(visible.count + other.count, Self.maxListed)
        if omitted > 0 { lines.append("(\(omitted) more elements not listed)") }
        lines.append("")
        lines.append("IMPORTANT: Only use identifiers appearing in this vocabulary. Do not invent accessibility identifiers. If no observed identifier can express the requested action, represent the limitation explicitly (omit the identifier and label rather than fabricate one).")
        return lines.joined(separator: "\n")
    }
}
