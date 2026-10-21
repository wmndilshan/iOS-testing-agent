import Foundation

public struct ScenarioLocator: Codable, Sendable, Equatable {
    public let role: String
    public let identifier: String?
    public let label: String?

    public init(role: String, identifier: String? = nil, label: String? = nil) {
        self.role = role
        self.identifier = identifier
        self.label = label
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
}
