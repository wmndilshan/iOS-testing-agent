import Foundation
import AgentCore

/// A device command the person is asked to allow.
public struct DeviceApproval: Identifiable, Equatable, Sendable {
    public let id: String
    /// The command in words, for example "Press the HOME button".
    public let phrase: String
    public let risk: DeviceCommandRisk
    /// Destructive commands cannot be allowed for the whole chat.
    public let offersChatGrant: Bool
}

public enum DeviceAnswer: Sendable { case approveOnce, allowForChat, deny }

extension AgentChatState {
    /// True while the agents wait for the person: a question about a run, or a device command to allow.
    public var isWaitingForPerson: Bool { prompt != nil || deviceApproval != nil }

    /// The agents asked for a device command. It is checked, then run, asked about, or refused, and the result goes back to them.
    func handleDeviceRequest(_ event: [String: Any]) {
        let id = event["id"] as? String ?? ""
        Task {
            let reply = await self.deviceHandler.handle(event)
            self.write(["t": "device-result", "id": id, "ok": reply.ok, "text": reply.ok ? reply.text : "FAILED: " + reply.text, "file": reply.file ?? ""])
        }
    }

    /// The person's answer to the banner. With no question open it does nothing.
    public func answerDevice(_ answer: DeviceAnswer) { deviceHandler.answer(answer) }
}
