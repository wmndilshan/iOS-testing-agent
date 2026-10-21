import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition
@testable import AgentEngine

@Suite("Device tools for the agents")
struct DeviceToolsTests {
    private let tools = DeviceTools.tools(inbox: AgentInbox(), reporter: AgentReporter())

    private func properties(_ tool: AgentTool) -> [String: AnyCodableValue] {
        guard case .dictionary(let schema) = tool.spec.schema, case .dictionary(let properties)? = schema["properties"] else { return [:] }
        return properties
    }

    private func commandNames(_ tool: AgentTool) -> [String] {
        guard case .dictionary(let command)? = properties(tool)["command"], case .array(let options)? = command["enum"] else { return [] }
        return options.compactMap(\.stringValue)
    }

    @Test("Six grouped tools, each offering exactly its group's commands, and every command is reachable through one of them")
    func grouping() {
        #expect(tools.map(\.spec.name) == ["device_observe", "device_input", "device_app", "device_environment", "device_files", "device_system"])
        let offered = tools.flatMap { commandNames($0) }
        #expect(Set(offered) == Set(DeviceCommandKind.allCases.map(\.rawValue)) && offered.count == DeviceCommandKind.allCases.count, "no command twice, none missing")
        #expect(commandNames(tools[1]) == DeviceCommandCatalog.specs(in: .input).map { $0.kind.rawValue })
    }

    @Test("A tool's schema has the command, the optional target, and the union of its commands' arguments")
    func schema() {
        let input = properties(tools[1])
        #expect(Set(["command", "target", "label", "identifier", "x", "y", "seconds", "x1", "y2", "direction", "scale", "text", "key", "button"]).isSubset(of: input.keys))
        guard case .dictionary(let key)? = input["key"], case .array(let keys)? = key["enum"] else { Issue.record("no key enum"); return }
        #expect(keys.compactMap(\.stringValue).contains("return"))
        guard case .dictionary(let x)? = input["x"] else { Issue.record("no x"); return }
        #expect(x["type"] == .string("integer"))
    }

    @Test("The description says which commands change the device and which are destructive, so the model expects the question")
    func descriptions() {
        let app = tools[2].spec.description
        #expect(app.contains("- uninstall_app(bundle_id): Uninstall an app and delete its data [destructive: the person is asked every time]"))
        #expect(app.contains("- open_url(url): ") && app.contains("[changes the device: the person is asked]"))
        let observe = tools[0].spec.description
        #expect(observe.contains("- describe_screen(?filter): ") && !observe.contains("describe_screen(?filter): List what is on screen: labels, identifiers, types and positions of the elements. Start here, then act by label. ["))
    }

    @Test("A command that belongs to another tool, or does not exist, is refused before anything is sent")
    func wrongCommand() async {
        await #expect(throws: RepoSandbox.Refused.self) { _ = try await tools[0].run(["command": .string("tap")]) }
        await #expect(throws: RepoSandbox.Refused.self) { _ = try await tools[1].run(["command": .string("rm_rf")]) }
        await #expect(throws: RepoSandbox.Refused.self) { _ = try await tools[1].run([:]) }
    }

    @Test("Device tools run one at a time, never in parallel")
    func sequential() {
        #expect(tools.allSatisfy { !$0.parallelSafe })
    }
}
