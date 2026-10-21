import Foundation

public struct AppIdentity: Codable, Sendable, Equatable, Hashable {
    public let bundleID: String
    public let displayName: String?
    public let version: String?
    public let build: String?

    public init(
        bundleID: String,
        displayName: String? = nil,
        version: String? = nil,
        build: String? = nil
    ) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.version = version
        self.build = build
    }

    /// Strict, fail-closed compatibility assessment.
    ///
    /// A confirmed `bundleID`, `version`, or `build` mismatch is `.incompatible` — the skill
    /// legitimately belongs to a different app/release and must be skipped. `build` mismatches
    /// are checked with the same semantics as `version`. When `version`/`build` is recorded on ONE side but missing on the other, that
    /// is a genuine ambiguity — this is never silently treated as `.compatible`; it is
    /// `.revalidationRequired`. When the field is absent on BOTH sides (this deployment does not
    /// track it at all), there is nothing to contradict, so it does not by itself block
    /// compatibility — but it also does not, by itself, establish it beyond the confirmed fields.
    public func assessCompatibility(with other: AppIdentity) -> AppCompatibilityAssessment {
        guard bundleID == other.bundleID else {
            return .incompatible(reason: "Bundle ID mismatch: '\(bundleID)' vs '\(other.bundleID)'.")
        }
        switch (version, other.version) {
        case (nil, nil):
            break
        case (.some(let v1), .some(let v2)):
            guard v1 == v2 else {
                return .incompatible(reason: "App version mismatch: skill='\(v1)', current='\(v2)'.")
            }
        default:
            return .revalidationRequired(reason: "App version is recorded on one identity but missing on the other; compatibility cannot be confirmed.")
        }
        switch (build, other.build) {
        case (nil, nil):
            break
        case (.some(let b1), .some(let b2)):
            guard b1 == b2 else {
                return .incompatible(reason: "App build mismatch: skill='\(b1)', current='\(b2)'.")
            }
        default:
            return .revalidationRequired(reason: "App build is recorded on one identity but missing on the other; compatibility cannot be confirmed.")
        }
        return .compatible
    }
}

/// Fail-closed outcome of comparing a learned skill's recorded app identity against the app
/// identity currently under test.
public enum AppCompatibilityAssessment: Sendable, Equatable {
    /// Bundle ID, version, and build all matched (or were absent on both sides in a way that
    /// still permits a definite compatibility conclusion).
    case compatible
    /// A confirmed mismatch (different bundle ID, version, or build) — the skill belongs to a
    /// different app/release and must not be reused.
    case incompatible(reason: String)
    /// Required identity information (version and/or build) is missing on one side, so
    /// compatibility cannot be confirmed either way. Callers must treat this as untrusted rather
    /// than assuming compatibility, and should fall back to fresh LLM reasoning.
    case revalidationRequired(reason: String)
}
