import Testing
import Foundation
@testable import AgentGateway

/// The skill's tool reference is generated from the catalogue; these fail when it is stale, and when the skill stops pointing at real tools.
@Suite("Skill and docs stay in step with the tools")
struct SkillSyncTests {
    private let services = GatewayServices(projectRoot: URL(fileURLWithPath: "/tmp"), deviceControl: nil, launcher: nil)

    @Test("references/tools.md equals the generated Markdown; regenerate with `tool list --markdown`")
    func referenceIsCurrent() throws {
        let generated = GatewayCommandLine.markdown(Gateway(tools: GatewayCatalogue.tools(services)))
        let file = try String(contentsOf: RepositoryRoot.url.appendingPathComponent("skills/autonomous-testing-agent/references/tools.md"), encoding: .utf8)
        #expect(file.trimmingCharacters(in: .whitespacesAndNewlines) == generated.trimmingCharacters(in: .whitespacesAndNewlines),
                "skills/autonomous-testing-agent/references/tools.md is out of date: AutonomousTestingAgent tool list --markdown > skills/autonomous-testing-agent/references/tools.md")
    }

    @Test("The skill has a name and description, and every tool it names exists")
    func skillNamesRealTools() throws {
        let skill = try String(contentsOf: RepositoryRoot.url.appendingPathComponent("skills/autonomous-testing-agent/SKILL.md"), encoding: .utf8)
        #expect(skill.hasPrefix("---\nname: autonomous-testing-agent\ndescription: "))
        let tools = Set(GatewayCatalogue.tools(services).map(\.name))
        let mentioned = Set(skill.components(separatedBy: "`").filter { $0.hasPrefix("device_") || ["list_cases", "read_case", "write_case", "run_case", "get_report", "list_runs", "plan_tests"].contains($0) })
        #expect(!mentioned.isEmpty && mentioned.isSubset(of: tools), "\(mentioned.subtracting(tools))")
    }

    @Test("The integration guide and AGENTS.md exist and point at the skill")
    func docs() throws {
        let guide = try String(contentsOf: RepositoryRoot.url.appendingPathComponent("docs/INTEGRATIONS.md"), encoding: .utf8)
        #expect(guide.contains("ata-mcp") && guide.contains("tool call") && guide.contains("confirm: true"))
        let agents = try String(contentsOf: RepositoryRoot.url.appendingPathComponent("AGENTS.md"), encoding: .utf8)
        #expect(agents.contains("skills/autonomous-testing-agent/SKILL.md"))
    }
}
