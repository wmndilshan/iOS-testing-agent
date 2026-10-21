import Foundation
import AgentCore
import AgentInfrastructure

/// How the agent process asks the app to run a device command: it sends the request, the app validates it, asks the person where its policy says to,
/// runs it, and sends the result back. The bridge never touches the device; it is one function, so a test can stand in for the app.
struct DeviceBridge: Sendable {
    /// Runs a command and returns what the app said: the result, or text starting `FAILED:`.
    let send: @Sendable (DeviceCommand) async -> String

    init(send: @escaping @Sendable (DeviceCommand) async -> String) { self.send = send }

    init(inbox: AgentInbox, reporter: AgentReporter, timeout: TimeInterval = 600) {
        send = { command in
            guard let data = try? JSONEncoder().encode(command), let object = try? JSONSerialization.jsonObject(with: data) else { return "FAILED: That command could not be sent." }
            let id = "device-\(UUID().uuidString.prefix(8))"
            reporter.send(["t": "agent-device-request", "id": id, "command": object])
            // The person may be asked first; an unanswered question must not leave the team waiting for ever.
            guard let result = await inbox.next(kind: "device-result", id: id, timeout: timeout) else {
                return "FAILED: The app did not answer the device request in time. Nothing is known about whether it ran."
            }
            return result.text
        }
    }

    func run(_ kind: DeviceCommandKind, _ arguments: [String: DeviceValue] = [:]) async -> String { await send(DeviceCommand(kind, arguments)) }
}
