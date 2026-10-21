import Foundation

public enum TrustedValidationResult: Sendable, Equatable {
    case valid(scenario: SafeScenario, targetElement: UIElementSnapshot)
    case rejected(reason: String)

    public var isValid: Bool {
        if case .valid = self { return true }
        return false
    }

    public var rejectionReason: String? {
        if case .rejected(let reason) = self { return reason }
        return nil
    }

    public static func == (lhs: TrustedValidationResult, rhs: TrustedValidationResult) -> Bool {
        switch (lhs, rhs) {
        case (.valid(let s1, let e1), .valid(let s2, let e2)):
            return s1.id == s2.id && e1.id == e2.id
        case (.rejected(let r1), .rejected(let r2)):
            return r1 == r2
        default:
            return false
        }
    }
}

// MARK: - TrustedActionValidator
