import Foundation
import ImageIO
import AgentCore
import AgentInfrastructure

/// The device tools: six grouped by what is asked of the device (like the agent runtime's own), generated from `DeviceCommandCatalog`, plus a
/// listing of every command with its risk. They run through the shared `DeviceCommandPipeline`; a destructive command also needs `confirm: true`.
enum DeviceGatewayTools {
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
        Group(tool: "device_system", title: "Boot or shut down simulators, or erase one", groups: [.system]),
    ]

    static func tools(_ services: GatewayServices) -> [GatewayTool] {
        let session = DeviceSession(services: services)
        var made = groups.compactMap { group -> GatewayTool? in
            let specs = group.groups.flatMap { DeviceCommandCatalog.specs(in: $0) }
            guard !specs.isEmpty else { return nil }
            let kinds = Set(specs.map(\.kind))
            let list = specs.map { spec -> String in
                let params = spec.params.map { ($0.required ? "" : "?") + $0.name }.joined(separator: ", ")
                let note = spec.risk == .destructive ? " [destructive: needs confirm=true]" : ""
                return "- \(spec.kind.rawValue)\(params.isEmpty ? "" : "(\(params))"): \(spec.summary)\(note)"
            }.joined(separator: "\n")
            var properties = properties(for: specs)
            properties["confirm"] = Schema.boolean("Only for a destructive command: true after the person has agreed to it")
            return GatewayTool(name: group.tool, description: "\(group.title). Commands:\n\(list)", properties: properties, required: ["command"],
                               readOnly: specs.allSatisfy { $0.risk == .readOnly }) { args, _ in
                await session.run(args, allowed: kinds)
            }
        }
        made.append(GatewayTool(name: "device_sequence", description: "Do several device commands in one call and get the screen's changes back: saves round trips. Each step is {command, …its arguments}, from device_input, device_app, device_environment or device_observe; at most 12; it stops at the first failure. A destructive command is refused here: call it on its own.",
                                properties: ["steps": Schema.array(of: Schema.object(["command": Schema.string("A device command, for example tap, type_text, press_key, launch_app")], required: ["command"]), "The commands, in order, each with its own arguments"),
                                             "settle_ms": Schema.integer("Pause after each step, default 300")], required: ["steps"], readOnly: false) { args, progress in
            guard case .array(let raw)? = args["steps"], (1...12).contains(raw.count) else { return .error("steps must be a list of 1 to 12 commands.") }
            let allowed = Set(groups.filter { $0.tool != "device_system" && $0.tool != "device_files" }.flatMap { $0.groups.flatMap { DeviceCommandCatalog.specs(in: $0) } }.map(\.kind))
            let pause = UInt64(max(0, min(args.int("settle_ms") ?? 300, 3000))) * 1_000_000
            var lines: [String] = []
            for (index, item) in raw.enumerated() {
                guard case .dictionary(let step) = item, let name = step.string("command"), let kind = DeviceCommandKind(rawValue: name), allowed.contains(kind) else {
                    return .error((lines + ["step \(index + 1): not a command this tool runs. Use device_input, device_app, device_environment or device_observe commands."]).joined(separator: "\n"))
                }
                progress("step \(index + 1) of \(raw.count): \(name)", Double(index) / Double(raw.count))
                let result = await session.execute(step, kind: kind, allowDestructive: false)
                lines.append("step \(index + 1) \(name): " + result.plainText.split(separator: "\n").first.map(String.init).orEmpty)
                if result.isError { return .error(lines.joined(separator: "\n") + "\nStopped at step \(index + 1); the rest were not run.") }
                try? await Task.sleep(nanoseconds: pause)
            }
            let screen = await session.execute(["command": .string("read_screen"), "mode": .string("state")], kind: .readScreen)
            return .text(lines.joined(separator: "\n") + "\n--- the screen now\n" + screen.plainText)
        })
        made.append(GatewayTool(name: "list_device_commands", description: "Every device command with its tool, risk and arguments.", properties: [:], readOnly: true) { _, _ in
            .text(commandListing())
        })
        return made
    }

    static func commandListing() -> String {
        groups.flatMap { group in
            group.groups.flatMap { DeviceCommandCatalog.specs(in: $0) }.map { spec in
                let params = spec.params.map { ($0.required ? "" : "?") + $0.name }.joined(separator: ", ")
                return "\(group.tool) \(spec.kind.rawValue)(\(params)) [\(spec.risk)] \(spec.summary)"
            }
        }.joined(separator: "\n")
    }

    /// One schema for the tool: `command`, the optional `target`, and the union of its commands' arguments.
    static func properties(for specs: [DeviceCommandSpec]) -> [String: AnyCodableValue] {
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

/// Runs device commands for one gateway: remembers the target, validates, applies the confirm rule and shapes the result.
actor DeviceSession {
    private let services: GatewayServices
    private var remembered: DeviceTarget?

    init(services: GatewayServices) { self.services = services }

    func run(_ args: [String: AnyCodableValue], allowed: Set<DeviceCommandKind>) async -> GatewayResult {
        guard let name = args.string("command"), let kind = DeviceCommandKind(rawValue: name), allowed.contains(kind) else {
            return .error("command must be one of: \(allowed.map(\.rawValue).sorted().joined(separator: ", ")).")
        }
        return await execute(args, kind: kind)
    }

    /// One command from tool arguments: validated, refused if destructive and unconfirmed, run on the remembered or booted simulator.
    func execute(_ args: [String: AnyCodableValue], kind: DeviceCommandKind, allowDestructive: Bool = true) async -> GatewayResult {
        guard let control = services.deviceControl else { return .error("Device control is not available: idb was not found (see the README).") }
        var arguments: [String: DeviceValue] = [:]
        for (key, value) in args where !["command", "target", "confirm"].contains(key) {
            switch value {
            case .string(let text): arguments[key] = .string(text)
            case .int(let number): arguments[key] = .number(Double(number))
            case .double(let number): arguments[key] = .number(number)
            case .bool(let flag): arguments[key] = .bool(flag)
            default: return .error("“\(key)” must be text, a number or true/false.")
            }
        }
        let pipeline = DeviceCommandPipeline(control: control, context: DeviceValidationContext(projectRoot: services.projectRoot, repository: nil))
        do {
            let prepared = try pipeline.prepare(DeviceCommand(kind, arguments, target: args.string("target")))
            if prepared.risk == .destructive, !allowDestructive || args.bool("confirm") != true {
                return .error("“\(prepared.phrase)” is destructive and cannot be undone. Nothing was changed. Ask the person; if they agree, call it on its own with confirm=true.")
            }
            let (result, used) = try await pipeline.run(prepared, remembered: remembered)
            if remembered == nil { remembered = used }
            return shaped(result, kind: kind)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    /// A screenshot goes back as a picture (compressed, so it is cheap to read) as well as its path; everything else is text.
    private func shaped(_ result: DeviceCommandResult, kind: DeviceCommandKind) -> GatewayResult {
        var content: [GatewayContent] = [.text(result.text)]
        if kind == .screenshot, let path = result.filePath, let data = FileManager.default.contents(atPath: path),
           let jpeg = ScreenshotCompressor.jpeg(from: data) {
            content = [.image(base64: jpeg.base64EncodedString(), mimeType: "image/jpeg"), .text("\(result.text)\nSaved at \(path)\n" + ScreenshotGeometry.hint(full: data, sent: jpeg))]
        }
        return GatewayResult(content: content, isError: !result.ok)
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}

/// What a vision agent needs to turn a point on the screenshot into a tap: the picture it is sent is shrunk, so say how its pixels map to the
/// screen's points.
enum ScreenshotGeometry {
    static func hint(full: Data, sent: Data) -> String {
        guard let big = size(of: full), let small = size(of: sent) else { return "" }
        let scale: Double = (1100...1400).contains(big.width) ? 3 : 2
        let points = (big.width / scale, big.height / scale)
        let ratio = points.0 / small.width
        return String(format: "The picture is %.0f×%.0f px for a %.0f×%.0f point screen: tap x = picture x × %.2f, y = picture y × %.2f.", small.width, small.height, points.0, points.1, ratio, points.1 / small.height)
    }

    static func size(of data: Data) -> (width: Double, height: Double)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double, let height = properties[kCGImagePropertyPixelHeight] as? Double else { return nil }
        return (width, height)
    }
}
