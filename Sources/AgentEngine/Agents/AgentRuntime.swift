import Foundation
import AgentCore
import AgentInfrastructure

/// What the agent run reports to the app: one `@@EVENT` line each, through the same `emit` the case runner uses.
struct AgentReporter: Sendable {
    private static let lock = NSLock()

    /// Safe from any thread and in order: agents run off the main actor.
    func send(_ event: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) else { return }
        Self.lock.lock()
        print("@@EVENT \(text)")
        fflush(stdout)
        Self.lock.unlock()
    }
}

/// One line the app wrote to the agent's input.
struct AgentInput: Sendable {
    let kind: String
    let id: String
    let text: String
}

/// Reads the agent's standard input on its own thread and hands lines to whoever is waiting for them.
final class AgentInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [AgentInput] = []
    private var waiters: [(token: UUID, match: (AgentInput) -> Bool, continuation: CheckedContinuation<AgentInput?, Never>)] = []
    private var closed = false
    /// Pause, resume and stop do not wait their turn in the queue: they act at once, whatever the agents are waiting for.
    var controlHandler: (@Sendable (String) -> Void)?

    func start() {
        Thread.detachNewThread { [self] in
            var open = true
            while open {
                // A pool per line: this thread lives as long as the process and never drains one by itself.
                autoreleasepool {
                    guard let line = readLine(strippingNewline: true) else { open = false; return }
                    guard let data = line.data(using: .utf8), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
                    deliver(AgentInput(kind: object["t"] as? String ?? "", id: object["id"] as? String ?? "", text: object["text"] as? String ?? ""))
                }
            }
            lock.lock(); closed = true
            let pending = waiters; waiters = []
            lock.unlock()
            pending.forEach { $0.continuation.resume(returning: nil) }
        }
    }

    private func deliver(_ input: AgentInput) {
        if ["pause", "resume", "stop"].contains(input.kind), let controlHandler {
            controlHandler(input.kind)
            return
        }
        lock.lock()
        if let index = waiters.firstIndex(where: { $0.match(input) }) {
            let waiter = waiters.remove(at: index)
            lock.unlock()
            waiter.continuation.resume(returning: input)
        } else {
            queue.append(input)
            lock.unlock()
        }
    }

    /// An input of this kind that has already arrived, without waiting for one.
    func takeQueued(kind: String) -> AgentInput? {
        lock.lock(); defer { lock.unlock() }
        guard let index = queue.firstIndex(where: { $0.kind == kind }) else { return nil }
        return queue.remove(at: index)
    }

    /// The next input of this kind (and id, when given). Nil when the app closed the input.
    /// With `timeout` (seconds), gives up and returns nil when nothing arrives in time.
    func next(kind: String, id: String? = nil, timeout: TimeInterval? = nil) async -> AgentInput? {
        let match: (AgentInput) -> Bool = { $0.kind == kind && (id == nil || $0.id == id) }
        let token = UUID()
        return await withCheckedContinuation { continuation in
            lock.lock()
            if let index = queue.firstIndex(where: match) {
                let input = queue.remove(at: index)
                lock.unlock()
                continuation.resume(returning: input)
            } else if closed {
                lock.unlock()
                continuation.resume(returning: nil)
            } else {
                waiters.append((token, match, continuation))
                lock.unlock()
                if let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
                        lock.lock()
                        guard let index = waiters.firstIndex(where: { $0.token == token }) else { lock.unlock(); return }
                        let waiter = waiters.remove(at: index)
                        lock.unlock()
                        waiter.continuation.resume(returning: nil)
                    }
                }
            }
        }
    }
}

/// What the agents of one conversation share.
actor AgentState {
    var caseKey: String?
    var bundleID: String?
    var lastRun: String?
    var llmCalls = 0
    let maxLLMCalls: Int
    private(set) var inputTokens = 0
    private(set) var outputTokens = 0
    private(set) var cachedTokens = 0
    let startedAt = Date()

    init(maxLLMCalls: Int = 60) { self.maxLLMCalls = maxLLMCalls }

    func setCase(key: String, bundleID: String?) { caseKey = key; self.bundleID = bundleID }
    func setLastRun(_ text: String) { lastRun = text }

    /// What each specialist last reported, kept so a later "continue" does not redo finished work.
    private(set) var reports: [String: String] = [:]
    func setReport(_ agent: String, _ text: String) { reports[agent] = String(text.prefix(3000)) }

    /// Everything worth remembering across a restart of the agent process, as flat text the app can store.
    func facts() -> [String: String] {
        var out = reports.reduce(into: [String: String]()) { $0["report.\($1.key)"] = $1.value }
        if let caseKey { out["caseKey"] = caseKey }
        if let bundleID, !bundleID.isEmpty { out["bundleID"] = bundleID }
        if let lastRun { out["lastRun"] = String(lastRun.prefix(3000)) }
        return out
    }

    func restore(facts: [String: String]) {
        caseKey = facts["caseKey"] ?? caseKey
        bundleID = facts["bundleID"] ?? bundleID
        lastRun = facts["lastRun"] ?? lastRun
        for (key, value) in facts where key.hasPrefix("report.") { reports[String(key.dropFirst(7))] = value }
    }

    /// The facts as a block for the orchestrator's task.
    func factsBlock() -> String {
        var lines: [String] = []
        if let caseKey { lines.append("Case written so far: \(caseKey)\(bundleID.map { " (app \($0))" } ?? "")") }
        for (agent, text) in reports.sorted(by: { $0.key < $1.key }) { lines.append("Last report of \(agent):\n\(text)") }
        if let lastRun { lines.append("Result of the last simulator run:\n\(lastRun)") }
        return lines.isEmpty ? "" : "Known from earlier in this conversation (do not redo finished work):\n" + lines.joined(separator: "\n") + "\n\n"
    }
    func addUsage(input: Int, output: Int, cached: Int) { inputTokens += input; outputTokens += output; cachedTokens += cached }
    /// Counts one model call; false once the budget of the conversation is spent.
    func takeCall() -> Bool { llmCalls += 1; return llmCalls <= maxLLMCalls }
}

/// A tool an agent can call. Errors become the tool's result so the model can correct itself.
struct AgentTool: Sendable {
    let spec: AgentToolSpec
    /// False for a tool that changes something or must happen in order: calls in one turn then run one after another.
    let parallelSafe: Bool
    let run: @Sendable ([String: AnyCodableValue]) async throws -> String

    init(name: String, description: String, properties: [String: AnyCodableValue] = [:], required: [String] = [], parallelSafe: Bool = true,
         run: @escaping @Sendable ([String: AnyCodableValue]) async throws -> String) {
        self.parallelSafe = parallelSafe
        spec = AgentToolSpec(name: name, description: description, schema: .dictionary([
            "type": .string("object"), "properties": .dictionary(properties), "required": .array(required.map { .string($0) }),
        ]))
        self.run = run
    }
}

enum Schema {
    static func string(_ description: String) -> AnyCodableValue { .dictionary(["type": .string("string"), "description": .string(description)]) }
    static func boolean(_ description: String) -> AnyCodableValue { .dictionary(["type": .string("boolean"), "description": .string(description)]) }
    static func integer(_ description: String) -> AnyCodableValue { .dictionary(["type": .string("integer"), "description": .string(description)]) }
    static func number(_ description: String) -> AnyCodableValue { .dictionary(["type": .string("number"), "description": .string(description)]) }
    static func choice(_ options: [String], _ description: String) -> AnyCodableValue {
        .dictionary(["type": .string("string"), "enum": .array(options.map { .string($0) }), "description": .string(description)])
    }
    static func array(of item: AnyCodableValue, _ description: String) -> AnyCodableValue {
        .dictionary(["type": .string("array"), "description": .string(description), "items": item])
    }
    static func object(_ properties: [String: AnyCodableValue], required: [String]) -> AnyCodableValue {
        .dictionary(["type": .string("object"), "properties": .dictionary(properties), "required": .array(required.map { .string($0) })])
    }
}

extension Dictionary where Key == String, Value == AnyCodableValue {
    func string(_ key: String) -> String? { self[key]?.stringValue }
    func int(_ key: String) -> Int? {
        switch self[key] {
        case .int(let value)?: return value
        case .double(let value)?: return Int(value)
        case .string(let text)?: return Int(text)
        default: return nil
        }
    }
}

/// One agent: a system prompt, tools and a model. `run` loops model call, tool calls, tool results until the model answers in text.
struct Agent: Sendable {
    let name: String
    let role: String
    let system: String
    let tools: [AgentTool]
    let llm: any ToolCallingLLM
    let maxTurns: Int
    /// Tool calls one run may make. Past it the tools answer "write your answer now" without running, so an agent cannot wander.
    var maxToolCalls = 40
    /// When set, the agent waits here while paused and stops when stopped (checked before each model turn and before each batch of tool calls).
    var gate: PauseGate?

    enum Failure: Error, LocalizedError {
        case budgetSpent
        case stopped
        var errorDescription: String? {
            switch self {
            case .budgetSpent: "The agent team used its model-call budget."
            case .stopped: "Stopped."
            }
        }
    }

    func run(task: String, state: AgentState, reporter: AgentReporter) async throws -> String {
        reporter.send(["t": "agent-start", "agent": name, "role": role, "model": llm.modelName, "task": task])
        var messages: [AgentMessage] = [.user(task)]
        var toolCallsUsed = 0
        let specs = tools.map(\.spec)
        for turn in 1...maxTurns {
            try await checkpoint()
            guard await state.takeCall() else { throw Failure.budgetSpent }
            var text = "", reasoning = ""
            var calls: [ToolCall] = [], opaque: [String: String] = [:]
            let modelStarted = Date()
            for try await event in llm.respond(system: system, messages: messages, tools: specs) {
                switch event {
                case .reasoningDelta(let delta):
                    reasoning += delta
                    reporter.send(["t": "agent-think", "agent": name, "delta": delta])
                case .textDelta(let delta):
                    text += delta
                    reporter.send(["t": "agent-text", "agent": name, "delta": delta])
                case .toolCall(let call, let token):
                    calls.append(call)
                    if let token { opaque[call.id] = token }
                case .usage(let input, let output, let cached):
                    await state.addUsage(input: input, output: output, cached: cached)
                    reporter.send(["t": "agent-usage", "agent": name, "input": input, "output": output, "cached": cached,
                                   "ms": Int(Date().timeIntervalSince(modelStarted) * 1000), "totalInput": await state.inputTokens,
                                   "totalOutput": await state.outputTokens, "totalCached": await state.cachedTokens])
                case .done: break
                }
            }
            reporter.send(["t": "agent-turn-end", "agent": name])
            messages.append(.assistant(text: text, calls: calls, reasoning: reasoning, opaque: opaque))
            if calls.isEmpty { return text }
            try await checkpoint()
            for call in calls {
                reporter.send(["t": "agent-tool", "agent": name, "id": call.id, "name": call.name, "args": Self.summary(of: call.arguments)])
            }
            // Calls the model made together run together when each is read-only; results go back in the model's order.
            let parallel = calls.count > 1 && calls.allSatisfy { call in tools.first { $0.spec.name == call.name }?.parallelSafe ?? true }
            var outcomes = [String?](repeating: nil, count: calls.count)
            let budget = max(0, maxToolCalls - toolCallsUsed)
            toolCallsUsed += calls.count
            if parallel {
                await withTaskGroup(of: (Int, String).self) { group in
                    for (index, call) in calls.enumerated() { group.addTask { (index, await execute(call, reporter: reporter, allowed: index < budget)) } }
                    for await (index, result) in group { outcomes[index] = result }
                }
            } else {
                for (index, call) in calls.enumerated() { outcomes[index] = await execute(call, reporter: reporter, allowed: index < budget) }
            }
            for (index, call) in calls.enumerated() { messages.append(.toolResult(callID: call.id, name: call.name, content: outcomes[index] ?? "")) }
            if turn == maxTurns { messages.append(.user("Turn limit reached: answer now with what you have.")) }
        }
        guard await state.takeCall() else { throw Failure.budgetSpent }
        var final = ""
        for try await event in llm.respond(system: system, messages: messages, tools: []) {
            if case .textDelta(let delta) = event { final += delta; reporter.send(["t": "agent-text", "agent": name, "delta": delta]) }
        }
        return final
    }

    /// A safe place to pause or stop: waits while paused, and throws when stopped.
    private func checkpoint() async throws {
        guard let gate else { return }
        await gate.checkpoint()
        if await gate.isStopped { throw Failure.stopped }
    }

    /// Runs one tool and reports it. The result is clipped as it enters the conversation and never changed afterwards, so the
    /// conversation prefix stays identical from turn to turn and the provider's prompt cache keeps hitting.
    private func execute(_ call: ToolCall, reporter: AgentReporter, allowed: Bool) async -> String {
        let started = Date()
        let result: String, ok: Bool
        if !allowed {
            result = "Tool budget spent (\(maxToolCalls) calls). Do not call more tools: write your final answer now from what you already have."; ok = false
        } else if let tool = tools.first(where: { $0.spec.name == call.name }) {
            do { result = try await tool.run(call.arguments); ok = true }
            catch { result = "Error: \(error.localizedDescription)"; ok = false }
        } else {
            result = "Error: there is no tool named \(call.name)."; ok = false
        }
        let clipped = result.count > Self.maxResultCharacters ? String(result.prefix(Self.maxResultCharacters)) + "\n…(truncated; ask for a narrower window)" : result
        reporter.send(["t": "agent-tool-result", "agent": name, "id": call.id, "ok": ok, "summary": String(clipped.prefix(600)),
                       "ms": Int(Date().timeIntervalSince(started) * 1000), "chars": clipped.count])
        return clipped
    }

    static let maxResultCharacters = 5_000

    private static func summary(of arguments: [String: AnyCodableValue]) -> String {
        guard let data = try? JSONEncoder().encode(arguments), let text = String(data: data, encoding: .utf8) else { return "" }
        return String(text.prefix(800))
    }
}
