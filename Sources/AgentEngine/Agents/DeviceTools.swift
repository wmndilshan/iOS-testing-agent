import Foundation
import AgentCore
import AgentInfrastructure

/// The agents' hands: six tools, one per kind of thing a device can be asked, generated from the device command catalog. They only send a request;
/// the app validates it, asks the person where its policy says to, runs it on the device and sends the result back. Nothing here touches idb.
enum DeviceTools {
    private struct Group {
        let tool: String
        let title: String
        let groups: [DeviceCommandGroup]
    }

    private static let groups = [
        Group(tool: "device_observe", title: "Look at the device without changing it", groups: [.observe]),
        Group(tool: "device_input", title: "Touch, type and press buttons", groups: [.input]),
        Group(tool: "device_app", title: "Open links, and launch, stop, install or uninstall apps", groups: [.app]),
        Group(tool: "device_environment", title: "Set location, permissions, notifications, appearance, photos and contacts", groups: [.environment]),
        Group(tool: "device_files", title: "Read and write files inside an app's container", groups: [.files]),
        Group(tool: "device_system", title: "Boot or shut down the simulator, or erase it", groups: [.system]),
    ]

    /// All six tools, for the chat team's DeviceOperator.
    static func tools(inbox: AgentInbox, reporter: AgentReporter) -> [AgentTool] {
        tools(bridge: DeviceBridge(inbox: inbox, reporter: reporter))
    }

    /// The tools of one agent: only the named tools (nil: all) and, inside them, only the allowed commands (nil: all). An agent gets exactly the hands it needs.
    static func tools(bridge: DeviceBridge, only names: Set<String>? = nil, allowing allowed: Set<DeviceCommandKind>? = nil) -> [AgentTool] {
        groups.filter { names?.contains($0.tool) ?? true }.compactMap { group in
            let specs = group.groups.flatMap { DeviceCommandCatalog.specs(in: $0) }.filter { allowed?.contains($0.kind) ?? true }
            guard !specs.isEmpty else { return nil }
            let kinds = Set(specs.map(\.kind))
            let list = specs.map { spec -> String in
                let note = spec.risk == .destructive ? " [destructive: the person is asked every time]" : spec.risk == .reversible ? " [changes the device: the person is asked]" : ""
                let params = spec.params.map { ($0.required ? "" : "?") + $0.name }.joined(separator: ", ")
                return "- \(spec.kind.rawValue)\(params.isEmpty ? "" : "(\(params))"): \(spec.summary)\(note)"
            }.joined(separator: "\n")
            return AgentTool(name: group.tool, description: "\(group.title). Commands:\n\(list)", properties: properties(for: specs), required: ["command"], parallelSafe: false) { args in
                guard let name = args.string("command"), let kind = DeviceCommandKind(rawValue: name), kinds.contains(kind) else {
                    throw RepoSandbox.Refused(reason: "command must be one of: \(specs.map { $0.kind.rawValue }.joined(separator: ", ")).")
                }
                var arguments: [String: DeviceValue] = [:]
                for (key, value) in args where key != "command" && key != "target" {
                    switch value {
                    case .string(let text): arguments[key] = .string(text)
                    case .int(let number): arguments[key] = .number(Double(number))
                    case .double(let number): arguments[key] = .number(number)
                    case .bool(let flag): arguments[key] = .bool(flag)
                    default: throw RepoSandbox.Refused(reason: "“\(key)” must be text, a number or true/false.")
                    }
                }
                return await bridge.send(DeviceCommand(kind, arguments, target: args.string("target")))
            }
        }
    }

    /// One schema for the tool: `command`, the optional `target`, and the union of its commands' arguments.
    private static func properties(for specs: [DeviceCommandSpec]) -> [String: AnyCodableValue] {
        var properties: [String: AnyCodableValue] = [
            "command": Schema.choice(specs.map { $0.kind.rawValue }, "Which command to run"),
            "target": Schema.string("Optional: the id of a simulator or device from list_targets; default the booted simulator"),
        ]
        for spec in specs {
            for param in spec.params where properties[param.name] == nil {
                switch param.type {
                case .integer: properties[param.name] = Schema.integer(param.help)
                case .number: properties[param.name] = Schema.number(param.help)
                case .choice(let options): properties[param.name] = Schema.choice(options, param.help)
                default: properties[param.name] = Schema.string(param.help)
                }
            }
        }
        return properties
    }
}
