import Foundation

/// Read-only view of the production source tree for architecture tests. Layout-agnostic: it finds
/// the repository by Package.swift and classifies files by folder name and type-file prefix.
enum SourceTree {
    struct File {
        let path: String      // repo-relative
        let text: String
        var name: String { (path as NSString).lastPathComponent }
        var components: [String] { path.split(separator: "/").map(String.init) }
        /// The module a file belongs to ("AgentCore", "AgentInfrastructure", "GUI", ...), from its path under `Sources/`.
        var module: String? {
            let c = components
            return c.count > 2 && c[0] == "Sources" ? c[1] : nil
        }
        /// The architectural layer: the folder under `AgentCore` ("Domain", "Security", ...) or, for the other library modules, the layer the module
        /// implements ("Infrastructure", "Presentation", "App" for the composition root). Nil outside the five library modules.
        var layer: String? {
            let c = components
            switch module {
            case "AgentCore": return c.count > 3 ? c[2] : nil
            case "AgentInfrastructure": return "Infrastructure"
            case "AgentPresentation": return "Presentation"
            case "AgentComposition": return "App"
            default: return nil
            }
        }
        func inLayer(_ layer: String) -> Bool { self.layer == layer || components.dropLast().contains(layer) }
        /// Code with comment lines removed, so audits inspect code, not prose about code.
        var code: String {
            text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
        }
        /// Code with comments, string literals and multi-line strings blanked out, for symbol references.
        var symbols: String {
            var s = code
            s = s.replacingOccurrences(of: "\"\"\"[\\s\\S]*?\"\"\"", with: "\"\"", options: .regularExpression)
            s = s.replacingOccurrences(of: "\"[^\"\\n]*\"", with: "\"\"", options: .regularExpression)
            return s
        }
        var isController: Bool { name.hasPrefix("ScenarioExecutionController") }
        var isDispatcher: Bool { name == "ScenarioStepDispatcher.swift" }
        var isUIState: Bool { name.hasPrefix("AgentUIState") }
        var isCLI: Bool { path.hasPrefix("Sources/AgentEngine/") }
    }

    static let all: [File] = {
        let root = RepositoryRoot.url
        guard let e = FileManager.default.enumerator(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil) else { return [] }
        var out: [File] = []
        for case let url as URL in e where url.pathExtension == "swift" {
            let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
            out.append(File(path: rel, text: (try? String(contentsOf: url, encoding: .utf8)) ?? ""))
        }
        return out.sorted { $0.path < $1.path }
    }()

    /// The four library modules the old single `AgentCore` module was split into.
    static let coreModules: Set<String> = ["AgentCore", "AgentInfrastructure", "AgentPresentation", "AgentComposition"]
    static var core: [File] { all.filter { $0.module.map(coreModules.contains) ?? false } }

    /// The unit/integration test sources (for isolation audits).
    static let allTests: [File] = {
        let root = RepositoryRoot.url
        guard let e = FileManager.default.enumerator(at: root.appendingPathComponent("Tests/AutonomousTestingAgentTests"), includingPropertiesForKeys: nil) else { return [] }
        var out: [File] = []
        for case let url as URL in e where url.pathExtension == "swift" {
            out.append(File(path: url.path.replacingOccurrences(of: root.path + "/", with: ""), text: (try? String(contentsOf: url, encoding: .utf8)) ?? ""))
        }
        return out.sorted { $0.path < $1.path }
    }()
}
