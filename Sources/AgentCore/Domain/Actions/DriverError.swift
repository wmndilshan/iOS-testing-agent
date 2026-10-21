import Foundation

public enum DriverError: Error, LocalizedError, Equatable {
    case staleSnapshot(requested: String, current: String)
    case elementNotFound(String)
    case elementNotHittable(String)
    case elementDisabled(String)
    case typeMismatch(expected: String, actual: String, elementID: String)
    case ambiguousElement(String, count: Int, candidates: [ElementCandidateSummary])
    case actionFailed(String)
    case simulatorNotAvailable(String)
    case observationFailed(String)
    /// The capability has no implementation in the current mode (e.g. a gesture in live mode). Nothing was done.
    case unsupportedCapability(String)
    /// A bounded wait or operation ran out of time.
    case timedOut(String)
    /// The capture or action was of another application than the one requested (or not in the foreground). Nothing
    /// observed there may stand in for the expected application.
    case wrongApplication(expected: String, observed: String, verdict: ApplicationIdentityVerdict = .mismatch)

    /// Marker in the description so a message-only consumer can still classify it.
    public static let wrongApplicationMarker = "APPLICATION_IDENTITY_MISMATCH"

    public static func ambiguousElement(_ id: String, count: Int) -> DriverError {
        .ambiguousElement(id, count: count, candidates: [])
    }

    public var errorDescription: String? {
        switch self {
        case .staleSnapshot(let req, let curr):
            return "Stale snapshot reference: requested snapshot '\(req)', but latest snapshot is '\(curr)'. Re-observe required."
        case .elementNotFound(let id):
            return "Element with ID '\(id)' was not found in the current accessibility snapshot."
        case .elementNotHittable(let id):
            return "Element with ID '\(id)' exists but is not hittable (obscured or offscreen)."
        case .elementDisabled(let id):
            return "Element with ID '\(id)' is disabled."
        case .typeMismatch(let expected, let actual, let id):
            return "Element type mismatch for '\(id)': expected '\(expected)', but resolved element has type '\(actual)'. A \(actual) cannot be targeted as a \(expected)."
        case .ambiguousElement(let id, let count, let candidates):
            if candidates.isEmpty {
                return "Identifier '\(id)' matched \(count) elements; unique reference required."
            } else {
                let candidateDescriptions = candidates.map { "\($0.role)(\($0.label ?? $0.identifier ?? $0.elementID))" }.joined(separator: ", ")
                return "Identifier '\(id)' matched \(count) candidate elements [\(candidateDescriptions)]; unique reference or more specific locator required."
            }
        case .actionFailed(let reason):
            return "Driver action failed: \(reason)"
        case .simulatorNotAvailable(let udid):
            return "Simulator '\(udid)' is not running or accessible."
        case .observationFailed(let reason):
            return "OBSERVATION_FAILED: \(reason)"
        case .unsupportedCapability(let what):
            return "Unsupported capability: \(what)"
        case .timedOut(let what):
            return "Timed out: \(what)"
        case .wrongApplication(let expected, let observed, let verdict):
            return "\(Self.wrongApplicationMarker)[\(verdict.rawValue)]: expected '\(expected)' in the foreground, observed '\(observed)'."
        }
    }
}
