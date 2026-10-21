import Foundation
import AgentCore
import AgentInfrastructure

/// The agents of an operating run, each with the few tools it needs and a short prompt. Workers use the fast model; only planning after a failure
/// uses the strong one. Nothing here touches the device: device tools go through the bridge to the app.
struct OperatorTeam: Sendable {
    let planner: Agent
    let replanner: Agent
    let gate: PauseGate
    let navigator: Agent
    let configurator: Agent
    let inspector: Agent
    let verifier: Agent

    static let maxGoals = 10

    init(strong: any ToolCallingLLM, fast: any ToolCallingLLM, bridge: DeviceBridge, board: OperatorBoard, gate: PauseGate) {
        self.gate = gate
        let kinds = GoalKind.allCases.map(\.rawValue)
        let goalSchema = Schema.object([
            "text": Schema.string("One small step, in plain words, that can be seen to have happened"),
            "kind": Schema.choice(kinds, "navigate: tap/type/scroll in the app. configure: open a link, launch an app, a permission, location, appearance. inspect: read something off the screen. verify: only check something is true"),
            "expected": Schema.string("What the screen shows when the step worked; quote exact visible labels in quotes"),
        ], required: ["text", "kind", "expected"])
        @Sendable func goals(from args: [String: AnyCodableValue]) throws -> [OperatorGoal] {
            guard case .array(let raw)? = args["goals"], (1...Self.maxGoals).contains(raw.count) else { throw PlanRefused(reason: "give 1 to \(Self.maxGoals) goals.") }
            return try raw.enumerated().map { index, item in
                guard case .dictionary(let fields) = item, let text = fields.string("text"), !text.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw PlanRefused(reason: "goal \(index + 1) needs text.")
                }
                return OperatorGoal(number: index + 1, text: text, kind: GoalKind(rawValue: fields.string("kind") ?? "") ?? .navigate, expected: fields.string("expected") ?? "")
            }
        }
        let setPlan = AgentTool(name: "set_plan", description: "Save the plan: the ordered goals of the task. Call once.", properties: ["goals": Schema.array(of: goalSchema, "Ordered goals")],
                                required: ["goals"], parallelSafe: false) { args in
            let parsed = try goals(from: args)
            await board.setGoals(parsed)
            return "Plan saved: \(parsed.count) goal(s)."
        }
        let replan = AgentTool(name: "set_plan", description: "Save the new plan for what is still to do. Call once.", properties: ["goals": Schema.array(of: goalSchema, "Ordered goals still to do")],
                               required: ["goals"], parallelSafe: false) { args in
            let parsed = try goals(from: args)
            await board.replan(with: parsed)
            return "Plan saved: \(parsed.count) goal(s) still to do."
        }
        let verdict = AgentTool(name: "report_verdict", description: "Report whether the goal's expected result is on screen now. Call exactly once.",
                                properties: ["passed": Schema.boolean("True only when the expected result is really there"), "evidence": Schema.string("What you saw that decides it, in one sentence")],
                                required: ["passed", "evidence"], parallelSafe: false) { args in
            var passed = false
            if case .bool(let flag)? = args["passed"] { passed = flag } else if args.string("passed")?.lowercased() == "true" { passed = true }
            await board.setVerdict(passed: passed, evidence: String((args.string("evidence") ?? "").prefix(300)))
            return "Verdict recorded."
        }
        let blocked = AgentTool(name: "report_blocked", description: "Call instead of report_verdict when the screen needs the person and nothing more can be done without them: a login or password, a verification code, a CAPTCHA, a payment, a permission only they can give.",
                                properties: ["reason": Schema.string("What the person has to do, in one sentence")], required: ["reason"], parallelSafe: false) { args in
            await board.setBlocked(String((args.string("reason") ?? "The screen needs you.").prefix(300)))
            return "The person will be asked to take over."
        }
        let finding = AgentTool(name: "report_finding", description: "Report what you found out. Call exactly once.", properties: ["answer": Schema.string("The answer, short and exact")],
                                required: ["answer"], parallelSafe: false) { args in
            await board.add(finding: String((args.string("answer") ?? "").prefix(400)))
            return "Finding recorded."
        }
        func withGate(_ agent: Agent) -> Agent { var copy = agent; copy.gate = gate; return copy }

        planner = withGate(Agent(name: "Orchestrator", role: "Plans the task", system: Self.plannerPrompt, tools: [setPlan], llm: fast, maxTurns: 3, maxToolCalls: 4))
        replanner = withGate(Agent(name: "Orchestrator", role: "Plans again after a failure", system: Self.plannerPrompt, tools: [replan], llm: strong, maxTurns: 3, maxToolCalls: 4))
        navigator = withGate(Agent(name: "Navigator", role: "Taps, types and scrolls", system: Self.navigatorPrompt,
                                   tools: DeviceTools.tools(bridge: bridge, only: ["device_input", "device_app"], allowing: Self.navigatorCommands) + DeviceTools.tools(bridge: bridge, only: ["device_observe"], allowing: [.waitFor]), llm: fast, maxTurns: 3, maxToolCalls: 4))
        configurator = withGate(Agent(name: "Configurator", role: "Opens links, apps, permissions, location, appearance", system: Self.configuratorPrompt,
                                      tools: DeviceTools.tools(bridge: bridge, only: ["device_app", "device_environment", "device_files", "device_system"]) + DeviceTools.tools(bridge: bridge, only: ["device_observe"], allowing: [.listApps]), llm: fast, maxTurns: 3, maxToolCalls: 4))
        inspector = withGate(Agent(name: "Inspector", role: "Reads the screen", system: Self.inspectorPrompt,
                                   tools: DeviceTools.tools(bridge: bridge, only: ["device_observe"], allowing: Self.observingCommands) + [finding], llm: fast, maxTurns: 4, maxToolCalls: 5))
        verifier = withGate(Agent(name: "Verifier", role: "Checks the result", system: Self.verifierPrompt,
                                  tools: DeviceTools.tools(bridge: bridge, only: ["device_observe"], allowing: [.find, .look, .readScreen, .readElement, .waitFor]) + [verdict, blocked], llm: fast, maxTurns: 3, maxToolCalls: 3))
    }

    // MARK: Which commands each agent may use

    static let navigatorCommands: Set<DeviceCommandKind> = [.tap, .doubleTap, .longPress, .swipe, .scroll, .scrollTo, .typeText, .pressKey, .pressButton]
    static let observingCommands: Set<DeviceCommandKind> = [.readScreen, .find, .readElement, .waitFor, .look, .readLog, .listApps, .describePoint]

    // MARK: Prompts

    static let plannerPrompt = """
    You plan how to carry out a task on an iOS simulator. A team will do each goal one at a time: a Navigator (taps, types, scrolls), a Configurator (links, apps, \\
    permissions, location, appearance), an Inspector (reads the screen) and a Verifier. Split the task into at most \\(maxGoals) small goals; each is one thing that can be seen to \\
    have happened, with its expected result (quote exact visible labels). Pick each goal's kind: a goal that checks whether something is true (a setting is on, a label is shown) is verify; inspect is only for reading a value or text off the screen to report it. Start from the screen you are shown; do not repeat what is already true. \\
    Prefer a configure goal for what a device command does directly (open a URL or an app, appearance such as dark or light mode, location, permissions, keyboard, language) over tapping through the Settings app. Call set_plan once and then reply 'planned'.
    """
    static let navigatorPrompt = """
    You operate the app on a simulator for one goal. When an action makes something load, wait_for what you expect (one call) instead of guessing. You are given the screen as a short list of controls with #numbers. Do the next ONE step toward the goal with one tool call; \\
    chain up to three calls only when each clearly follows the last (tap a field, then type). Tap by #number (tap with handle) or by label, never by guessed coordinates. \\
    Stay inside the app on screen: never open other apps or links (that is the Configurator's job), and never uninstall, erase or delete. Do not look at the screen again: it is given to you. When done, say in one sentence what you did.
    """
    static let configuratorPrompt = """
    You change the device or open things on it for one goal: open a URL, launch an app, grant or revoke a permission, set the location or appearance. Use the one tool call that does it. Change only what the goal asks for. If you do not know an app's bundle id, call list_apps first and use the id it shows; never guess one. \\
    Never uninstall, erase or clear anything unless the goal says so. When done, say in one sentence what you did.
    """
    static let inspectorPrompt = """
    You find something out from the simulator's screen for one goal. Use the screen you are given first; use find for something scrolled out of view, and look (it reads the actual picture) \\
    only when the list cannot answer, such as an icon without a label. Then call report_finding once with the exact answer.
    """
    static let verifierPrompt = """
    You check whether a goal's expected result is true now. If "Confirmed by the device itself" states what the goal expects (for example 'The device appearance is now dark'), call \\
    report_verdict passed at once, without looking: the device's own answer is better evidence than a picture, and a web page can stay light in dark mode. Otherwise judge from the screen \\
    list you are given and the changes since the last action; only if that is not enough use find or look. Call report_verdict once: passed only when the expected result is really there, \\
    with one sentence of evidence. If the screen shows a login, a code, a CAPTCHA or anything only the person can do, call report_blocked instead.
    """
}

/// A plan the Orchestrator gave that cannot be used; the reason goes back to it so it can fix the plan.
struct PlanRefused: Error, LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}
