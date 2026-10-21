import Foundation
import AgentCore
import AgentInfrastructure

/// The engine's entry point: the work the command line tool does. `run(arguments:)` picks one of four commands (run a case, run the agent team, run an
/// Operate task, plan tests); the rest of the engine is extensions of this type, one command or concern per file.
@MainActor
public enum Engine {
    public static func run(arguments args: [String]) async {
        // Unbuffered stdout: prompts and evidence appear immediately even when piped to a log,
        // so an operator relaying a human's approval can see exactly what is being approved.
        setvbuf(stdout, nil, _IONBF, 0)

        if args.contains("--plan-tests") {
            await runTestPlanner(args: args)
            return
        }

        if args.contains("--operate") {
            await runOperate(args: args)
            return
        }
        if args.contains("--agent") {
            await runAgent(args: args)
            return
        }

        // `--aio-run=` is the old spelling of `--run-case=` and stays as a hidden alias.
        if let arg = args.first(where: { $0.hasPrefix("--run-case=") || $0.hasPrefix("--aio-run=") }),
           let equals = arg.firstIndex(of: "=") {
            await runCase(key: String(arg[arg.index(after: equals)...]), args: args)
            return
        }

        print("""
        Usage:
          AutonomousTestingAgent --run-case=<KEY> --mode=LIVE_AUTONOMOUS_AFTER_LOGIN|NON_LIVE_TEST
                                 [--bundle-id=<id>] [--start-step=N] [--end-step=N] [--skip-steps=8,12] [--username=<name>]
                                 [--skills=off] [--judge=off] [--judge-models=a,b] [--allow-destructive] [--refresh] [--events]
                                 [--provider=deepseek|gemini] [--model=<name>] [--max-consecutive-failures=N] [--retries=N] [--start-step=N] [--repo=<dir>] [--cases-dir=<dir>]
          AutonomousTestingAgent --agent --events --repo=<dir> [--provider=deepseek|gemini] [--model=<name>] [--scenario="..."]
          AutonomousTestingAgent --operate --events [--task="..."] [--provider=deepseek|gemini]
          AutonomousTestingAgent --plan-tests [--root=<dir>] [--base=<ref>] [--files=a,b] [--out=<dir>] [--format=json]
                                 [--tier=0...4] [--budget=<tokens>] [--depth=<n>] [--include-unverified] [--baseline-dir=<dir>]
        """)
        exit(1)
    }

    static var runContext: CLIRunContext?
}
