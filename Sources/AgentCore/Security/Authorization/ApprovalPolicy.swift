import Foundation

/// Single source of truth for the lifetime of a single-use approval token.
///
/// The token is created with the approval request, consumed exactly once by dispatch, and
/// expires after `tokenTimeToLive`. It is never restored across a process restart.
public enum ApprovalPolicy {
    public static let tokenTimeToLive: TimeInterval = 120

    public static func expiryDate(from creation: Date) -> Date {
        creation.addingTimeInterval(tokenTimeToLive)
    }

    public static var expiredMessage: String {
        "Approval expired (\(Int(tokenTimeToLive))s TTL)."
    }
}
