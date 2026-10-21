import Foundation

/// Explicit state identity derived from observation hierarchy, roles, identifiers, and modal state.
/// Raw screenshots are never used as the sole state identity.
public struct SkillStateFingerprint: Codable, Sendable, Hashable, Equatable {
    public let screenIdentity: String?
    public let relevantElementIDs: [String]
    public let elementRoles: [String]
    public let elementIdentifiers: [String]
    public let modalPresent: Bool
    public let navigationState: String?
    public let rawDigest: String

    public init(
        screenIdentity: String? = nil,
        relevantElementIDs: [String],
        elementRoles: [String],
        elementIdentifiers: [String],
        modalPresent: Bool,
        navigationState: String? = nil,
        rawDigest: String
    ) {
        self.screenIdentity = screenIdentity
        self.relevantElementIDs = relevantElementIDs
        self.elementRoles = elementRoles
        self.elementIdentifiers = elementIdentifiers
        self.modalPresent = modalPresent
        self.navigationState = navigationState
        self.rawDigest = rawDigest
    }

    /// Deterministically computes a state fingerprint from an observation snapshot.
    public static func compute(
        from observation: Observation,
        screenIdentity: String? = nil,
        navigationState: String? = nil
    ) -> Self {
        let sortedElements = observation.elements.sorted(by: { $0.id < $1.id })
        let relevantIDs = sortedElements.map { $0.id }
        let roles = sortedElements.map { $0.role }
        let identifiers = sortedElements.compactMap { $0.identifier }

        // Detect modal presence by checking sheet/dialog/alert elements or dimming containers
        let hasModal = observation.elements.contains { el in
            let r = el.role.lowercased()
            let id = (el.identifier ?? "").lowercased()
            let lbl = (el.label ?? "").lowercased()
            return r == "sheet" || r == "dialog" || r == "alert" ||
                   id.contains("modal") || id.contains("sheet") || id.contains("close") ||
                   lbl.contains("close") || lbl.contains("cancel")
        }

        var components: [String] = [
            "bundle:\(observation.bundleID)",
            "screen:\(screenIdentity ?? "default")",
            "modal:\(hasModal)",
            "nav:\(navigationState ?? "root")"
        ]
        for el in sortedElements {
            components.append("\(el.role):\(el.identifier ?? el.label ?? el.id):\(el.isEnabled):\(el.isHittable)")
        }

        let raw = components.joined(separator: "|")
        let hex = IntegrityHash.sha256Hex(raw)

        return SkillStateFingerprint(
            screenIdentity: screenIdentity,
            relevantElementIDs: relevantIDs,
            elementRoles: roles,
            elementIdentifiers: identifiers,
            modalPresent: hasModal,
            navigationState: navigationState,
            rawDigest: String(hex.prefix(16))
        )
    }
}
