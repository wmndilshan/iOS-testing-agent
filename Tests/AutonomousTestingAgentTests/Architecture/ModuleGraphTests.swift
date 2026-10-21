import Testing
import Foundation

/// The module split makes the layering a compile-time fact: a module that does not list another as a dependency cannot import it. These tests pin the
/// dependency lists in `Package.swift`, so adding an edge is a deliberate change here and in `ARCHITECTURE_RULES.md`.
@Suite("Module graph")
struct ModuleGraphTests {
    /// target name → its declared dependencies, read from Package.swift.
    private static let declared: [String: Set<String>] = {
        let text = (try? String(contentsOf: RepositoryRoot.url.appendingPathComponent("Package.swift"), encoding: .utf8)) ?? ""
        var result: [String: Set<String>] = [:]
        let pattern = #"\.(?:target|executableTarget)\(\s*name: "([\w-]+)",\s*dependencies: \[([^\]]*)\]"#
        let regex = try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let name = String(text[Range(match.range(at: 1), in: text)!])
            let list = String(text[Range(match.range(at: 2), in: text)!])
            // Only plain string dependencies count; `.product(...)` entries are external packages.
            let plain = list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.range(of: #"^"\w+"$"#, options: .regularExpression) != nil }
            result[name] = Set(plain.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) })
        }
        return result
    }()

    private static let expected: [String: Set<String>] = [
        "AgentCore": [],
        "AgentInfrastructure": ["AgentCore"],
        "AgentPresentation": ["AgentCore"],
        "AgentComposition": ["AgentCore", "AgentInfrastructure", "AgentPresentation"],
        "AgentEngine": ["AgentCore", "AgentInfrastructure", "CodeIntelligence", "TestCaseSources"],
        "AgentGateway": ["AgentCore", "AgentInfrastructure", "TestCaseSources"],
        "AgentMCP": ["AgentCore", "AgentGateway"],
        "ata-mcp": ["AgentGateway", "AgentMCP"],
        "AutonomousTestingAgent": ["AgentEngine", "AgentGateway"],
        "AutonomousTestingAgentApp": ["AgentCore", "AgentPresentation", "AgentComposition", "TestCaseSources"],
        "CodeIntelligence": [],
        "TestCaseSources": [],
    ]

    @Test("Every target depends on exactly the modules the architecture allows")
    func dependencies() {
        for (target, deps) in Self.expected {
            #expect(Self.declared[target] == deps, "\(target): declared \(Self.declared[target].map { Array($0).sorted() } ?? ["(missing)"]), expected \(deps.sorted())")
        }
    }

    @Test("The view-models cannot reach adapters, and nothing but the composition root and the engine sees both worlds")
    func isolation() {
        let presentation = Self.declared["AgentPresentation"] ?? ["?"]
        #expect(!presentation.contains("AgentInfrastructure") && !presentation.contains("AgentEngine") && !presentation.contains("AgentComposition"))
        let core = Self.declared["AgentCore"] ?? ["?"]
        #expect(core.isEmpty, "the core depends on nothing")
        let gateway = Self.declared["AgentGateway"] ?? ["?"]
        #expect(!gateway.contains("AgentEngine") && !gateway.contains("AgentPresentation") && !gateway.contains("AgentComposition"), "the gateway launches the CLI as a process; it does not link the engine or the UI")
        let mcp = Self.declared["AgentMCP"] ?? ["?"]
        #expect(!mcp.contains("AgentInfrastructure"), "the protocol layer never touches adapters")
        let both = Self.declared.filter { $0.value.contains("AgentInfrastructure") && $0.value.contains("AgentPresentation") }.map(\.key)
        #expect(both == ["AgentComposition"], "\(both)")
    }

    @Test("The command line tool is a thin shell over the engine")
    func thinCLI() throws {
        let main = try String(contentsOf: RepositoryRoot.url.appendingPathComponent("Sources/CLI/main.swift"), encoding: .utf8)
        #expect(main.split(separator: "\n").count < 20)
        #expect(Self.declared["AutonomousTestingAgent"] == ["AgentEngine", "AgentGateway"])
    }
}
