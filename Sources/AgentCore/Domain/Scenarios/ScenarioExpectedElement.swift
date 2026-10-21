import Foundation

public struct ScenarioExpectedElement: Codable, Sendable, Equatable, Identifiable {
    public var id: String {
        "\(role)_\(identifier ?? label ?? "unnamed")"
    }
    public let role: String
    public let identifier: String?
    public let label: String?
    public let requireNonZeroBounds: Bool
    public let requireEnabled: Bool
    public let requireHittable: Bool

    public init(
        role: String,
        identifier: String? = nil,
        label: String? = nil,
        requireNonZeroBounds: Bool = true,
        requireEnabled: Bool = false,
        requireHittable: Bool = false
    ) {
        self.role = role
        self.identifier = identifier
        self.label = label
        self.requireNonZeroBounds = requireNonZeroBounds
        self.requireEnabled = requireEnabled
        self.requireHittable = requireHittable
    }

    public func matches(element: UIElementSnapshot) -> Bool {
        if element.role != role { return false }
        if let id = identifier, !id.isEmpty {
            if element.identifier != id && element.label != id {
                if let lbl = label, !lbl.isEmpty, element.label == lbl {
                    return true
                }
                return false
            }
        } else if let lbl = label, !lbl.isEmpty, element.label != lbl {
            return false
        }
        return true
    }

    public func validate(against element: UIElementSnapshot) -> (passed: Bool, reason: String) {
        guard matches(element: element) else {
            return (false, "Element role or identifier/label mismatch.")
        }
        if requireNonZeroBounds {
            guard let frame = element.frame, frame.width > 0, frame.height > 0 else {
                return (false, "Element has zero or missing frame dimensions.")
            }
        }
        if requireEnabled && !element.isEnabled {
            return (false, "Element is disabled.")
        }
        if requireHittable && !element.isHittable {
            return (false, "Element is not hittable.")
        }
        return (true, "All criteria satisfied.")
    }
}
