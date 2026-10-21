import Foundation
import AgentCore
import AgentInfrastructure

/// The team: an orchestrator that delegates to four specialists, each with only its own tools.
/// No agent can approve, dispatch, or touch the device: running a case is a request the app carries out after the person approves.
struct AgentTeam: Sendable {
    let orchestrator: Agent
    let state: AgentState

    init(projectRoot: URL, sandbox: RepoSandbox, strong: any ToolCallingLLM, fast: any ToolCallingLLM, inbox: AgentInbox, reporter: AgentReporter, defaultBundleID: String, flow: AgentFlow = .full) {
        let state = AgentState()
        self.state = state
        func model(_ member: AgentFlow.Member) -> any ToolCallingLLM { member.tier == .strong ? strong : fast }

        let knowledge = RepoKnowledge(sandbox: sandbox, projectRoot: projectRoot)
        knowledge.prewarm()
        let analyst = Agent(
            name: "RepoAnalyst", role: "Reads the repository", system: """
            You study a local iOS app repository (read-only) so a test case can be written from facts. Work in this order and stop as soon as you can answer: \
            1) repo_overview (one call: bundle ids, entry points, navigation enums, screens, state models). \
            2) For each screen the scenario touches: ui_strings on its file or folder for the real labels, titles, buttons, fields and accessibility identifiers; \
            file_outline or describe_symbol only when the flow between screens is unclear. \
            3) search_text / read_file with a line window only for a specific gap. Avoid plan_tests unless behavior is unclear. \
            Make independent calls in the same turn so they run in parallel. Aim for 8 tool calls or fewer; the hard limit is 18. \
            Final report, at most 250 words: bundle id; the screens in flow order with their exact visible labels; preconditions (login, data, permissions). \
            Quote only labels you saw in tool results; never invent them.
            """, tools: AgentTools.repository(sandbox: sandbox, knowledge: knowledge), llm: model(flow.analyst), maxTurns: flow.analyst.maxTurns, maxToolCalls: flow.analyst.maxToolCalls)

        let author = Agent(
            name: "CaseAuthor", role: "Writes the test case", system: """
            You write one test case for an autonomous runner that drives the iOS simulator by looking at the live screen. \
            Call read_case on an existing case (list_cases first) to see the format. Each step is one thing a person does on screen: \
            'action' in plain words naming the visible label, 'data' for text to type, 'expected' for what must be visible afterwards. \
            Keep steps small and ordered, start with launching the app, avoid steps that cannot be seen on screen, and \
            never put real passwords in a case: use the text [CREDENTIALS] in the action of a password step. Steps that delete, \
            remove or log out need a person's approval at run time, so use them only when the scenario asks. \
            Choose a unique key like AGENT-<TOPIC>-1 and save with write_test_case. Reply with the key and the steps you saved.
            """, tools: AgentTools.author(projectRoot: projectRoot, state: state, reporter: reporter), llm: model(flow.author), maxTurns: flow.author.maxTurns, maxToolCalls: flow.author.maxToolCalls)

        let runner = Agent(
            name: "Runner", role: "Runs the case on the simulator", system: """
            You run a saved test case on the simulator with run_case, once. The person approves the run first; if they decline, \
            report that and stop. When it finishes, report the outcome (PASSED, FAILED, INCOMPLETE, BLOCKED or STOPPED) and the \
            result of each step exactly as returned. Do not retry a failed run yourself. When a run stopped at a failed step and you are asked to continue, \
            call run_case again with from_step set to that step, not from step 1.
            """, tools: AgentTools.runner(projectRoot: projectRoot, state: state, inbox: inbox, reporter: reporter), llm: model(flow.runner), maxTurns: flow.runner.maxTurns, maxToolCalls: flow.runner.maxToolCalls)

        let validator = Agent(
            name: "Validator", role: "Checks the result against the scenario", system: """
            You judge whether the run proves the original scenario. Read the case (read_case) and the run result (get_last_run_result). \
            Compare each step's result with its expected text and with what the scenario asked for. Verdict rules: PASS only when the run \
            PASSED and every scenario requirement maps to a passed step; FAIL when a step failed (name it and why, and whether it looks \
            like a product bug or a bad step); INCOMPLETE when steps were unsupported, skipped, blocked or the run did not happen. \
            Start your reply with 'VERDICT: PASS', 'VERDICT: FAIL' or 'VERDICT: INCOMPLETE', then give reasons and, on FAIL, a concrete fix for the case.
            """, tools: AgentTools.validator(projectRoot: projectRoot, state: state), llm: model(flow.validator), maxTurns: flow.validator.maxTurns, maxToolCalls: flow.validator.maxToolCalls)

        let deviceOperator = Agent(
            name: "DeviceOperator", role: "Controls the simulator", system: """
            You control the iOS simulator with the device tools, like a careful tester. Look first (device_observe describe_screen), act in one small step, then look again to \
            confirm it did what you meant. Tap by the visible label rather than guessed coordinates; use list_apps for bundle ids, open_url for links and deep links, \
            press_button for the hardware buttons. Every command that changes the device is checked by the person; if one is denied, stop and say what you could not do. \
            Use destructive commands (uninstall, clear, erase, delete) only when the person asked for exactly that. Never repeat a failing command: report what the device said. \
            Final report, at most 150 words: what you did and what the screen shows now.
            """, tools: DeviceTools.tools(inbox: inbox, reporter: reporter), llm: model(flow.device), maxTurns: flow.device.maxTurns, maxToolCalls: flow.device.maxToolCalls)

        func delegate(_ agent: Agent) -> @Sendable ([String: AnyCodableValue]) async throws -> String {
            { args in
                let task = args.string("task") ?? ""
                reporter.send(["t": "agent-handoff", "from": "Orchestrator", "to": agent.name, "task": task])
                let answer = try await agent.run(task: task, state: state, reporter: reporter)
                await state.setReport(agent.name, answer)
                reporter.send(["t": "agent-return", "from": agent.name, "to": "Orchestrator"])
                reporter.send(["t": "agent-memory", "facts": await state.facts()])
                return answer
            }
        }
        let taskProperty = ["task": Schema.string("What you need, with all context the specialist needs (it sees nothing else)")]

        let delegates: [(role: AgentFlow.Role, agent: Agent, tool: String, line: String, description: String)] = [
            (.analyst, analyst, "delegate_repo_analyst", "reads the local repository and CodeIntelligence to find the screens, labels and bundle id.", "Ask the repository analyst to study the repo for this scenario."),
            (.author, author, "delegate_case_author", "writes the test case file from the scenario and the analyst's findings.", "Ask the case author to write and save the test case."),
            (.runner, runner, "delegate_runner", "runs the saved case on the simulator (the person approves first).", "Ask the runner to run a saved case on the simulator."),
            (.validator, validator, "delegate_validator", "judges the last run against the scenario.", "Ask the validator to judge the last run against the scenario."),
            (.device, deviceOperator, "delegate_device_operator", "controls the simulator directly: looks at the screen, taps, types, opens links, presses buttons, sets location and permissions.", "Ask the device operator to do something on the simulator and report what the screen shows."),
        ].filter { flow[$0.role].enabled }
        let orderNames: [AgentFlow.Role: String] = [.analyst: "analyst", .author: "author", .runner: "runner", .validator: "validator", .device: "device operator"]
        // Only the case-writing team is named as missing; the device operator is simply not part of most flows.
        let skipped = AgentFlow.Role.allCases.filter { !flow[$0].enabled && $0 != .device }

        var prompt = "You lead a team that turns a test scenario into a verified simulator test. Specialists (call them with their tools):\n"
        prompt += delegates.map { "- \($0.tool): \($0.line)" }.joined(separator: "\n")
        prompt += "\nNormal order: " + delegates.map { orderNames[$0.role] ?? "" }.joined(separator: ", ") + ". "
        if flow.analyst.enabled {
            prompt += "Skip the analyst when the scenario names a built-in app (Safari, Settings) and needs no repository knowledge. "
        }
        prompt += "Call each specialist once when you can: put everything you need into one task (for the analyst: bundle id, the screens in flow order with exact labels and identifiers, preconditions, and anything else the author needs). Pass full context in each task: the scenario, bundle id, findings, case key. "
        if flow.author.enabled && flow.runner.enabled && flow.validator.enabled {
            prompt += "If the validator says FAIL because of a bad step, have the author write a corrected case under a new key and run it once more; never loop more than twice. "
        }
        prompt += "When the person says \"continue\", \"go on\", \"retry\" or similar, resume the unfinished work from the earlier conversation and the known facts: reuse reports and the saved case, and delegate only what is still missing. If no repository is configured, say so and work without it. Default app bundle id when none is found: \(defaultBundleID). "
        if !skipped.isEmpty {
            prompt += "This flow has no " + skipped.map { $0.rawValue }.joined(separator: ", ") + ": do not offer or promise that work, and say plainly what was left out. "
        }
        prompt += """
        Finish with a short report for the person: what was tested, the case key, the outcome, and the validator's reasons, and end with a last line \
        'VERDICT: PASS', 'VERDICT: FAIL', 'VERDICT: INCOMPLETE' or 'VERDICT: NONE' (when nothing was run, for example the person only asked a question).
        """

        orchestrator = Agent(
            name: "Orchestrator", role: "Plans and coordinates", system: prompt,
            tools: delegates.map { AgentTool(name: $0.tool, description: $0.description, properties: taskProperty, required: ["task"], run: delegate($0.agent)) },
            llm: strong, maxTurns: flow.orchestratorMaxTurns)
    }
}
