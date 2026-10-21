import Foundation
import AgentCore
import AgentInfrastructure

// `--operate --events [--task="..."] [--provider=deepseek|gemini]`
//
// A graph of agents that operates the simulator for a task: it plans, then for each goal reads the screen, acts, reads again and verifies. It never touches the
// device itself: every command is a request the app validates, asks the person about where needed, and runs. The app sends `{"t":"user","text":"..."}` for each task
// (the first can come from --task) and `pause`, `resume` and `stop` at any time. Everything is reported as `@@EVENT` lines.

@MainActor
extension Engine {
    static func runOperate(args: [String]) async {
        let flags = CaseRunFlags(args: args)
        let reporter = AgentReporter()
        func fail(_ message: String) async -> Never {
            reporter.send(["t": "agent-error", "message": message])
            print("✗ \(message)")
            exit(1)
        }

        let provider = flags.value("provider") ?? "deepseek"
        let strong: any ToolCallingLLM, fast: any ToolCallingLLM
        if provider == "gemini" {
            guard let config = try? Configuration.load() else { await fail("GEMINI_API_KEY was not found in the environment or .env.") }
            strong = GeminiToolCaller(apiKey: config.apiKey, model: flags.value("model") ?? config.model)
            fast = GeminiToolCaller(apiKey: config.apiKey, model: config.model)
        } else {
            guard let key = resolveDeepSeekAPIKey() else { await fail("DEEPSEEK_API_KEY was not found in the environment or .env.") }
            // Workers use the fast chat model; the strong reasoning model is only for planning again after a goal failed.
            strong = DeepSeekToolCaller(apiKey: key, model: flags.value("model") ?? "deepseek-reasoner", maxTokens: 16000, timeout: 120)
            // A worker call that has not answered in 45 s is not going to: the run says so instead of leaving the person watching a spinner.
            fast = DeepSeekToolCaller(apiKey: key, model: "deepseek-chat", timeout: 45)
        }

        let inbox = AgentInbox()
        let gate = PauseGate()
        inbox.controlHandler = { kind in
            Task {
                switch kind {
                case "pause": await gate.pause()
                case "resume": await gate.resume()
                default: await gate.stop()
                }
            }
        }
        inbox.start()
        let board = OperatorBoard()
        let state = AgentState(maxLLMCalls: 400)
        let appBridge = DeviceBridge(inbox: inbox, reporter: reporter)
        // What a command that changes the device reports (for example "The device appearance is now dark") is evidence the Verifier is shown.
        let observing = OperatorTeam.observingCommands
        let bridge = DeviceBridge { command in
            let reply = await appBridge.send(command)
            if !observing.contains(command.kind), !reply.hasPrefix("FAILED") { await board.record(action: "Result: " + String(reply.prefix(160))) }
            return reply
        }
        let hierarchy = OperatorHierarchy()
        do { try hierarchy.validate() } catch { await fail("The operator team is not valid: \(error)") }
        let team = OperatorTeam(strong: strong, fast: fast, bridge: bridge, board: board, gate: gate)
        let graph = OperatorGraph.make(team: team, board: board, bridge: bridge, reporter: reporter, state: state)
        do { try graph.validate() } catch { await fail("The operator graph is not valid: \(error)") }
        reporter.send(["t": "agent-ready", "mode": "operate", "model": fast.modelName, "strong": strong.modelName])
        reporter.send(["t": "graph-hierarchy", "orchestrator": OperatorHierarchy.orchestrator, "leads": hierarchy.payload])

        var pending: String? = flags.value("task")
        while true {
            let task: String
            if let first = pending { task = first; pending = nil }
            else if let input = await inbox.next(kind: "user") { task = input.text }
            else { return }
            guard !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            await gate.reset()
            await board.start(task: task)
            reporter.send(["t": "operate-start", "task": task])
            let started = Date()
            do {
                switch try await graph.run(board: board, reporter: reporter, gate: gate) {
                case .finished: break
                case .stopped:
                    reporter.send(["t": "operate-final", "status": "stopped", "summary": await board.summary(), "goals": OperatorBoard.payload(await board.goals), "actions": await board.sessionActions])
                case .stepLimit:
                    reporter.send(["t": "operate-final", "status": "failed", "summary": "The run reached its step limit.\n" + (await board.summary()), "goals": OperatorBoard.payload(await board.goals), "actions": await board.sessionActions])
                }
            } catch {
                reporter.send(["t": "agent-error", "message": error.localizedDescription])
            }
            reporter.send(["t": "operate-usage", "seconds": Int(Date().timeIntervalSince(started)), "calls": await state.llmCalls, "input": await state.inputTokens, "output": await state.outputTokens, "cached": await state.cachedTokens])
        }
    }

}
