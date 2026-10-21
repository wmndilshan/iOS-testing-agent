import Foundation

/// What a chat has been allowed to do on its own. Kept in memory per chat: a relaunch asks again.
public struct DeviceGrants: Equatable, Sendable {
    /// The person chose "allow device control for this chat": reversible commands run without asking.
    public var allowsReversible = false

    public init(allowsReversible: Bool = false) { self.allowsReversible = allowsReversible }
}

/// Whether a command may run now, or the person must be asked first. Pure, so the rules are checked by tests rather than by trust.
public enum DeviceControlPolicy {
    public enum Decision: Equatable, Sendable {
        case run
        /// Ask first. `offerChatGrant` adds "allow for this chat" to the question; destructive commands never offer it.
        case ask(offerChatGrant: Bool)
    }

    public static func decision(for risk: DeviceCommandRisk, grants: DeviceGrants) -> Decision {
        switch risk {
        case .readOnly: .run
        case .reversible: grants.allowsReversible ? .run : .ask(offerChatGrant: true)
        case .destructive: .ask(offerChatGrant: false)
        }
    }
}
