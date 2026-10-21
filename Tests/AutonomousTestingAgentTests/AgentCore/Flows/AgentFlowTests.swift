import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition
@testable import AgentEngine

private struct NamedLLM: ToolCallingLLM {
    let modelName: String
    func respond(system: String, messages: [AgentMessage], tools: [AgentToolSpec]) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private func team(_ flow: AgentFlow) -> AgentTeam {
    let root = ProductFixtures.tempDir()
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return AgentTeam(projectRoot: root, sandbox: RepoSandbox(root: root), strong: NamedLLM(modelName: "strong"), fast: NamedLLM(modelName: "fast"),
                     inbox: AgentInbox(), reporter: AgentReporter(), defaultBundleID: "com.apple.mobilesafari", flow: flow)
}

@Suite("Agent flows")
struct AgentFlowTests {
    @Test("The default flow is the team the app always had")
    func defaultTeam() {
        let orchestrator = team(.full).orchestrator
        #expect(orchestrator.tools.map(\.spec.name) == ["delegate_repo_analyst", "delegate_case_author", "delegate_runner", "delegate_validator"])
        #expect(orchestrator.maxTurns == 14 && orchestrator.llm.modelName == "strong")
        #expect(orchestrator.system.contains("Normal order: analyst, author, runner, validator. Skip the analyst when"))
        #expect(orchestrator.system.contains("never loop more than twice"))
        #expect(!orchestrator.system.contains("This flow has no"))
    }

    @Test("A flow without a specialist has no tool for it, and the prompt says what is left out")
    func disabledSpecialists() {
        let orchestrator = team(.authorOnly).orchestrator
        #expect(orchestrator.tools.map(\.spec.name) == ["delegate_repo_analyst", "delegate_case_author"])
        #expect(orchestrator.system.contains("Normal order: analyst, author."))
        #expect(!orchestrator.system.contains("delegate_runner") && !orchestrator.system.contains("never loop more than twice"))
        #expect(orchestrator.system.contains("This flow has no Runner, Validator"))
        #expect(team(.runExisting).orchestrator.tools.map(\.spec.name) == ["delegate_runner", "delegate_validator"])
    }

    @Test("Model tier and limits come from the flow")
    func tiersAndLimits() {
        var flow = AgentFlow.full
        flow.orchestratorMaxTurns = 5
        flow.analyst = AgentFlow.Member(tier: .strong, maxTurns: 3, maxToolCalls: 9)
        let built = team(flow)
        #expect(built.orchestrator.maxTurns == 5)
        // The delegate tools wrap the specialists; the default tiers are fast for the analyst and strong for the author.
        #expect(team(.full).orchestrator.llm.modelName == "strong")
        #expect(built.orchestrator.tools.count == 4)
    }

    @Test("Presets are usable, named, and each has the orchestrator")
    func presets() {
        #expect(AgentFlow.presets.map(\.name) == ["Full team", "Write cases only", "Run existing case", "Repository questions", "Device control"])
        for preset in AgentFlow.presets {
            #expect(preset.isUsable && preset.teamNames.first == "Orchestrator")
        }
        #expect(AgentFlow.full.teamNames == ["Orchestrator", "RepoAnalyst", "CaseAuthor", "Runner", "Validator"])
        #expect(AgentFlow.repositoryQuestions.teamNames == ["Orchestrator", "RepoAnalyst"])
        #expect(AgentFlow.deviceControl.teamNames == ["Orchestrator", "DeviceOperator"])
    }

    @Test("A flow survives the trip to the agent process, limits are clamped, and an empty team is refused")
    func handOver() throws {
        var flow = AgentFlow.authorOnly
        flow.author.maxTurns = 500
        flow.analyst.maxToolCalls = 0
        let json = try #require(flow.jsonString)
        let decoded = try #require(AgentFlow.decode(json))
        #expect(decoded.author.maxTurns == 20 && decoded.analyst.maxToolCalls == 1)
        #expect(decoded.runner.enabled == false)

        var empty = AgentFlow.full
        for role in AgentFlow.Role.allCases { empty[role].enabled = false }
        let emptyJSON = try #require(empty.jsonString)
        #expect(AgentFlow.decode(emptyJSON) == nil)
        #expect(AgentFlow.decode("not json") == nil)
    }

    @Test("The device operator is off in the default team and only delegated to in the device flow")
    func deviceOperator() {
        #expect(team(.full).orchestrator.tools.map(\.spec.name).contains("delegate_device_operator") == false)
        #expect(!team(.full).orchestrator.system.contains("device operator") && !team(.full).orchestrator.system.contains("DeviceOperator"))
        let device = team(.deviceControl).orchestrator
        #expect(device.tools.map(\.spec.name) == ["delegate_device_operator"])
        #expect(device.system.contains("Normal order: device operator."))
        #expect(device.system.contains("This flow has no RepoAnalyst, CaseAuthor, Runner, Validator"))
    }

    @Test("A flow saved before the device role existed still reads, with the device operator off")
    func oldFlowsStillRead() throws {
        let current = try #require(AgentFlow.full.jsonString)
        var object = try #require(JSONSerialization.jsonObject(with: Data(current.utf8)) as? [String: Any])
        object.removeValue(forKey: "device")
        let old = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        let flow = try #require(AgentFlow.decode(old))
        #expect(flow.device.enabled == false && flow.teamNames == AgentFlow.full.teamNames)
    }
}
