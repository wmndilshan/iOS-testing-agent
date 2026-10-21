import Foundation
import AgentCore
import AgentInfrastructure

/// Static test planning from a code change. It launches the command line tool's `--plan-tests`, which only reads the repository.
enum PlanGatewayTool {
    static func tool(_ services: GatewayServices) -> GatewayTool {
        GatewayTool(name: "plan_tests", description: "Plan tests for a code change by static analysis (touches no device): risk, impact, gaps and drafted specs, as JSON.",
                    properties: ["base": Schema.string("Git ref to compare against, default the repository's default"), "files": Schema.string("Comma-separated files to plan for instead of a git diff")],
                    readOnly: true) { args, progress in
            guard let launcher = services.launcher else { return .error("The test runner is not available.") }
            var arguments = ["--plan-tests", "--format=json", "--root=\(services.projectRoot.path)"]
            if let base = args.string("base") { arguments.append("--base=\(base)") }
            if let files = args.string("files") { arguments.append("--files=\(files)") }
            progress("Planning tests", nil)
            let handle: any CaseRunHandle
            do { handle = try launcher.launch(arguments: arguments) } catch { return .error(error.localizedDescription) }
            var output: [String] = []
            for await line in handle.lines { output.append(line) }
            let text = output.joined(separator: "\n")
            return .text(text.count > 40_000 ? String(text.prefix(40_000)) + "\n… (truncated)" : text)
        }
    }
}
