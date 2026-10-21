import Foundation
import SwiftUI
import AgentCore

/// A test case the CaseAuthor saved, as the chat shows it.
public struct AgentCaseInfo: Codable, Equatable, Sendable, Identifiable {
    public struct Step: Codable, Equatable, Sendable {
        public var number: Int
        public var action: String
        public var data: String
        public var expected: String
    }

    public var key: String
    public var title: String
    public var bundleID: String
    public var steps: [Step]
    public var id: String { key }

    static func parse(_ event: [String: Any]) -> AgentCaseInfo? {
        guard let key = event["key"] as? String, !key.isEmpty, let raw = event["steps"] as? [[String: Any]] else { return nil }
        let steps = raw.map { Step(number: $0["number"] as? Int ?? 0, action: $0["action"] as? String ?? "", data: $0["data"] as? String ?? "", expected: $0["expected"] as? String ?? "") }
        return AgentCaseInfo(key: key, title: event["title"] as? String ?? key, bundleID: event["bundleID"] as? String ?? "", steps: steps)
    }
}

/// One thing in the agent conversation: what the person said, what an agent thought or answered, a tool it called, or a hand-off.
public struct AgentChatMessage: Identifiable, Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable { case user, thinking, text, tool, handoff, verdict, error, notice, testCase }

    public var id = UUID()
    public var kind: Kind
    public var agent: String
    public var text: String
    /// Tool messages: the call id, its arguments, its result summary, and how it ended.
    public var callID = ""
    public var toolName = ""
    public var result: String?
    public var succeeded = true
    public var milliseconds: Int?
    /// Streaming messages stay open until the agent moves on.
    public var isOpen = false
    public var date = Date()
    /// When a thinking block closed or a tool call returned.
    public var endedAt: Date?
    /// Test case messages: the case itself.
    public var caseInfo: AgentCaseInfo?
}

/// The specialists of the team and what each is doing now.
public struct AgentStatus: Identifiable, Sendable, Equatable {
    public enum Phase: Sendable { case idle, working, done }
    public let id: String
    public var phase: Phase = .idle
    public var role = ""
}

/// Tokens the model providers billed for this conversation, and how many of the input came from their prompt cache.
public struct AgentUsage: Sendable, Equatable {
    public var input = 0
    public var output = 0
    public var cached = 0
    public var seconds = 0
    public var calls = 0

    public var cachedShare: Int { input == 0 ? 0 : Int((Double(cached) / Double(input) * 100).rounded()) }
    public var summary: String { "\(Self.short(input)) in · \(Self.short(output)) out · \(cachedShare)% cached" }

    static func short(_ n: Int) -> String { n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)" }
}

/// What the chat remembers between messages, restarts of the agent process, and launches of the app: the earlier turns (what the person
/// asked, what the team answered), and facts such as the case written, the app's bundle id, the last run and each specialist's report.
/// It belongs to one repository: choosing another one starts a fresh memory.
public struct AgentMemory: Codable, Equatable, Sendable {
    public struct Turn: Codable, Equatable, Sendable {
        public var user: String
        public var answer: String
    }

    public var repository = ""
    public var turns: [Turn] = []
    public var facts: [String: String] = [:]

    public var isEmpty: Bool { turns.isEmpty && facts.isEmpty }
    static let maxTurns = 12
    static let maxAnswerCharacters = 4000
}

/// The part of the chat that changes about ten times a second while an agent streams. It is its own object so that only the conversation
/// view watches it: the window, sidebar and app root observe `AgentChatState`, and must not be redrawn for every streamed word.
@MainActor
public final class AgentTranscript: ObservableObject {
    @Published public fileprivate(set) var revision = 0
    public init() {}
}

public struct AgentPrompt: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let message: String
    /// The case the question is about, when it is a request to run one.
    public let caseKey: String?
}

/// Where the repository the agents read is, and whether it can be used.
public enum RepositoryStatus: Equatable, Sendable {
    case notSet, missing, notAFolder, ready(swiftProject: Bool)

    public var isReady: Bool { if case .ready = self { return true } else { return false } }
}

/// The chat with the team of agents. It starts the agent as its own process, reads its events, and writes the person's messages and
/// answers back. A test run is started through the Run section's own state, so it is shown there and uses the same runner.
@MainActor
public final class AgentChatState: ObservableObject {
    public static let defaultsKey = "agent.repositoryPath"
    public static let providerKey = "agent.provider"
    /// The memory of the single conversation older versions kept; read once to import it as the first chat.
    public static let memoryKey = "agent.memory"
    public static let activeConversationKey = "agent.activeConversation"
    public static let flowKey = "agent.flow"

    /// The conversation. Not published itself: a model streams thousands of small pieces per answer, and redrawing the window for each one
    /// froze it. The conversation view watches `transcript.revision`, which changes at most about ten times a second.
    public private(set) var messages: [AgentChatMessage] = [] {
        didSet {
            publishSoon()
            if !isLoading { persistSoon() }
            let any = !messages.isEmpty
            if any != hasMessages { hasMessages = any }
        }
    }
    public let transcript = AgentTranscript()
    @Published public private(set) var hasMessages = false
    /// True while the "clear the conversation?" confirmation is showing.
    @Published public var isConfirmingClear = false
    /// How many earlier turns the agents will be reminded of.
    @Published public private(set) var rememberedTurns = 0
    /// Counts the person's messages, so the conversation view can jump to the end when they send one.
    @Published public private(set) var sendCount = 0
    @Published public private(set) var agents: [AgentStatus] = AgentFlow.full.teamNames.map { AgentStatus(id: $0) }
    /// How the team is set up. A change takes effect from the next message: the agents restart, and the chat's memory is handed to them again.
    @Published public private(set) var flow: AgentFlow = .full
    @Published public private(set) var isBusy = false
    @Published public private(set) var prompt: AgentPrompt?
    /// Test cases the agents saved in this conversation, by key.
    @Published public private(set) var cases: [String: AgentCaseInfo] = [:]
    @Published public private(set) var usage = AgentUsage()
    @Published public private(set) var lastCaseKey = ""
    @Published public private(set) var modelName = ""
    @Published public private(set) var repositoryPath: String
    /// The saved conversations, newest first. The one being shown is in it once it has something to save.
    @Published public private(set) var conversations: [ConversationSummary] = []
    @Published public private(set) var activeConversationID = UUID()
    @Published public private(set) var conversationTitle = ConversationSummary.untitled
    @Published public var provider: String { didSet { defaults.set(provider, forKey: Self.providerKey) } }

    var memory = AgentMemory()
    /// What the agents may do to the simulator, when idb is available. The agent process only asks; the app decides, asks the person, and runs it.
    let deviceControl: (any DeviceControlling)?
    /// A device command waiting for the person's answer, shown as a banner.
    @Published public internal(set) var deviceApproval: DeviceApproval?
    /// The simulator or device commands go to when a command names none.
    @Published public internal(set) var deviceTarget: DeviceTarget?
    let deviceHandler: DeviceRequestHandler
    private let store: ConversationStore
    private var createdAt = Date()
    /// True while a saved conversation is being put on screen: that is not a change worth saving.
    private var isLoading = false
    private var persistPending = false
    /// Off while a recorded conversation is replayed: a replay must never write into the saved memory.
    private var persistsMemory = true
    private var lastPublish = Date.distantPast
    private var publishPending = false
    private static let publishInterval: TimeInterval = 0.1

    let projectRoot: URL
    private let launcher: any CaseRunLaunching
    private let defaults: UserDefaults
    private var handle: (any CaseRunHandle)?
    private weak var caseRun: CaseRunState?
    private weak var workspace: WorkspaceState?

    public init(projectRoot: URL, launcher: any CaseRunLaunching, defaults: UserDefaults = .standard, conversationsDirectory: URL? = nil, deviceControl: (any DeviceControlling)? = nil) {
        self.projectRoot = projectRoot
        self.deviceControl = deviceControl
        deviceHandler = DeviceRequestHandler(control: deviceControl, projectRoot: projectRoot)
        store = ConversationStore(directory: conversationsDirectory ?? projectRoot.appendingPathComponent(".runs/chats", isDirectory: true))
        self.launcher = launcher
        self.defaults = defaults
        repositoryPath = defaults.string(forKey: Self.defaultsKey) ?? ""
        provider = defaults.string(forKey: Self.providerKey) ?? "deepseek"
        if let saved = defaults.string(forKey: Self.flowKey).flatMap(AgentFlow.decode) { flow = saved }
        agents = flow.teamNames.map { AgentStatus(id: $0) }
        deviceHandler.onApproval = { [weak self] in self?.deviceApproval = $0 }
        deviceHandler.onTarget = { [weak self] in self?.deviceTarget = $0 }
        deviceHandler.repository = { [weak self] in
            guard let self, self.repositoryStatus.isReady else { return nil }
            return URL(fileURLWithPath: (self.repositoryPath as NSString).expandingTildeInPath)
        }
        restoreActiveConversation()
    }

    // MARK: Flow

    /// Chooses how the team is set up. Ignored while the agents are working or when no specialist is enabled.
    public func setFlow(_ newFlow: AgentFlow) {
        let cleaned = newFlow.clamped
        guard !isBusy, cleaned.isUsable, cleaned != flow else { return }
        flow = cleaned
        agents = cleaned.teamNames.map { AgentStatus(id: $0) }
        if let json = cleaned.jsonString { defaults.set(json, forKey: Self.flowKey) }
        if handle != nil {
            endConversation()
            notice("Flow set to “\(cleaned.name)”. The next message starts the team this way and keeps what it remembers.")
        }
    }

    // MARK: Conversations

    /// The saved conversations plus, at the top, the one on screen when it has nothing to save yet.
    public var conversationRows: [ConversationSummary] {
        guard !conversations.contains(where: { $0.id == activeConversationID }) else { return conversations }
        return [ConversationSummary(id: activeConversationID, title: conversationTitle, createdAt: createdAt, updatedAt: createdAt, turns: 0)] + conversations
    }

    /// Opens the conversation that was open last time, else the newest one, else imports the single memory older versions kept.
    private func restoreActiveConversation() {
        conversations = store.list()
        if let raw = defaults.string(forKey: Self.activeConversationKey), let id = UUID(uuidString: raw), let record = store.load(id) {
            load(record)
        } else if let newest = conversations.first, let record = store.load(newest.id) {
            load(record)
        } else {
            restoreMemory()
            if !memory.isEmpty {
                conversationTitle = Self.title(from: memory.turns.first?.user ?? "")
                persistNow()
                defaults.removeObject(forKey: Self.memoryKey)
            }
        }
    }

    private func load(_ record: ConversationRecord) {
        deviceHandler.resetGrants()
        isLoading = true
        defer { isLoading = false }
        activeConversationID = record.summary.id
        createdAt = record.summary.createdAt
        conversationTitle = record.summary.title
        memory = record.memory
        rememberedTurns = memory.turns.count
        lastCaseKey = memory.facts["caseKey"] ?? ""
        cases = record.cases.filter { caseFileExists($0.key) }
        // A card for a case whose file is gone would offer a run that cannot start.
        var restored = record.messages.filter { $0.kind != .testCase || caseFileExists($0.caseInfo?.key ?? "") }
        for index in restored.indices { restored[index].isOpen = false }
        if !memory.turns.isEmpty { restored.append(Self.restoredNotice(memory.turns.count)) }
        messages = restored
        hasMessages = !restored.isEmpty
        usage = AgentUsage()
        defaults.set(record.summary.id.uuidString, forKey: Self.activeConversationKey)
    }

    private static func restoredNotice(_ turns: Int) -> AgentChatMessage {
        AgentChatMessage(kind: .notice, agent: "", text: "Restored \(turns) earlier turn\(turns == 1 ? "" : "s"). The agents remember them: say \"continue\" to pick up where you left off.")
    }

    private static func isRestoredNotice(_ message: AgentChatMessage) -> Bool { message.kind == .notice && message.text.hasPrefix("Restored ") }

    static func title(from text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let clean = line.trimmingCharacters(in: .whitespaces)
        if clean.isEmpty { return ConversationSummary.untitled }
        return clean.count > 48 ? String(clean.prefix(48)) + "…" : clean
    }

    private func persistSoon() {
        guard persistsMemory, !persistPending else { return }
        persistPending = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self else { return }
            self.persistPending = false
            self.persistNow()
        }
    }

    /// Writes the conversation on screen, or removes its file when nothing is left in it.
    private func persistNow() {
        guard persistsMemory else { return }
        let kept = messages.filter { !Self.isRestoredNotice($0) }
        if kept.isEmpty && memory.isEmpty {
            if conversations.contains(where: { $0.id == activeConversationID }) { store.delete(activeConversationID); conversations = store.list() }
            return
        }
        var recent = Array(kept.suffix(150))
        for index in recent.indices { recent[index].isOpen = false }
        let summary = ConversationSummary(id: activeConversationID, title: conversationTitle, createdAt: createdAt, updatedAt: Date(), turns: memory.turns.count)
        store.save(ConversationRecord(summary: summary, repository: repositoryPath, memory: memory, messages: recent, cases: cases))
        conversations = store.list()
        defaults.set(activeConversationID.uuidString, forKey: Self.activeConversationKey)
    }

    /// Starts an empty conversation. The one on screen is kept in the list. Agents still working in it are stopped.
    public func newConversation() {
        guard hasMessages || !memory.isEmpty else { return }
        endConversation()
        persistNow()
        isConfirmingClear = false
        deviceHandler.resetGrants()
        isLoading = true
        activeConversationID = UUID()
        createdAt = Date()
        conversationTitle = ConversationSummary.untitled
        messages = []
        isLoading = false
        memory = AgentMemory()
        cases = [:]
        lastCaseKey = ""
        rememberedTurns = 0
        usage = AgentUsage()
        defaults.set(activeConversationID.uuidString, forKey: Self.activeConversationKey)
    }

    /// Opens a saved conversation. Agents still working in the current one are stopped.
    public func select(_ id: UUID) {
        guard id != activeConversationID, let record = store.load(id) else { return }
        endConversation()
        persistNow()
        load(record)
    }

    public func rename(_ id: UUID, to title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if id == activeConversationID {
            conversationTitle = clean
            persistNow()
        } else if var record = store.load(id) {
            record.summary.title = clean
            store.save(record)
            conversations = store.list()
        }
    }

    public func delete(_ id: UUID) {
        guard id == activeConversationID else {
            store.delete(id)
            conversations = store.list()
            return
        }
        endConversation()
        store.delete(id)
        conversations = store.list()
        if let next = conversations.first, let record = store.load(next.id) {
            load(record)
        } else {
            memory = AgentMemory()
            deviceHandler.resetGrants()
            messages = []
            activeConversationID = UUID()
            createdAt = Date()
            conversationTitle = ConversationSummary.untitled
            cases = [:]
            lastCaseKey = ""
            rememberedTurns = 0
        }
    }

    /// Loads the saved memory when it is for the repository now set, and shows those turns again so the chat matches what the agents will know.
    private func restoreMemory() {
        guard let data = defaults.data(forKey: Self.memoryKey), let saved = try? JSONDecoder().decode(AgentMemory.self, from: data),
              saved.repository == repositoryPath, !saved.isEmpty else { return }
        memory = saved
        rememberedTurns = saved.turns.count
        lastCaseKey = saved.facts["caseKey"] ?? ""
        var restored: [AgentChatMessage] = []
        for turn in saved.turns {
            restored.append(AgentChatMessage(kind: .user, agent: "", text: turn.user))
            if !turn.answer.isEmpty { restored.append(AgentChatMessage(kind: .text, agent: "Orchestrator", text: turn.answer)) }
        }
        if let json = saved.facts["case.json"], let data = json.data(using: .utf8), let info = try? JSONDecoder().decode(AgentCaseInfo.self, from: data),
           FileManager.default.fileExists(atPath: caseFileURL(info.key).path) {
            var card = AgentChatMessage(kind: .testCase, agent: "CaseAuthor", text: info.title)
            card.caseInfo = info
            restored.append(card)
            cases[info.key] = info
        }
        if !saved.turns.isEmpty { restored.append(AgentChatMessage(kind: .notice, agent: "", text: "Restored \(saved.turns.count) earlier turn\(saved.turns.count == 1 ? "" : "s"). The agents remember them: say \"continue\" to pick up where you left off.")) }
        // Property observers do not run inside the initializer, so what they would update is set here.
        messages = restored
        hasMessages = !restored.isEmpty
    }

    private func saveMemory() {
        guard persistsMemory else { return }
        memory.repository = repositoryPath
        if memory.turns.count > AgentMemory.maxTurns { memory.turns.removeFirst(memory.turns.count - AgentMemory.maxTurns) }
        rememberedTurns = memory.turns.count
        persistNow()
    }

    /// Closes the newest turn when it never got an answer (stopped, failed, or the process ended), so the agents know it was left unfinished.
    private func closeOpenTurn(_ note: String) {
        guard let last = memory.turns.indices.last, memory.turns[last].answer.isEmpty else { return }
        memory.turns[last].answer = note
        saveMemory()
    }

    private func mergeFacts(_ facts: [String: String]) {
        guard !facts.isEmpty else { return }
        memory.facts.merge(facts) { _, new in new }
        lastCaseKey = memory.facts["caseKey"] ?? lastCaseKey
        saveMemory()
    }

    /// Lets the chat start runs in the Run section and switch to it. Called once by the window.
    public func bind(workspace: WorkspaceState, caseRun: CaseRunState) {
        self.workspace = workspace
        self.caseRun = caseRun
    }

    private func publishSoon() {
        let sinceLast = Date().timeIntervalSince(lastPublish)
        if sinceLast >= Self.publishInterval {
            lastPublish = Date()
            transcript.revision &+= 1
        } else if !publishPending {
            publishPending = true
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((Self.publishInterval - sinceLast) * 1_000_000_000))
                guard let self else { return }
                self.publishPending = false
                self.lastPublish = Date()
                self.transcript.revision &+= 1
            }
        }
    }

    // MARK: Repository setting

    public static func status(ofRepositoryAt path: String) -> RepositoryStatus {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .notSet }
        var isDirectory: ObjCBool = false
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) else { return .missing }
        guard isDirectory.boolValue else { return .notAFolder }
        let url = URL(fileURLWithPath: expanded)
        let hasPackage = FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path)
        let hasXcodeProject = ((try? FileManager.default.contentsOfDirectory(atPath: expanded)) ?? []).contains { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }
        return .ready(swiftProject: hasPackage || hasXcodeProject)
    }

    public var repositoryStatus: RepositoryStatus { Self.status(ofRepositoryAt: repositoryPath) }

    /// Saves the repository the agents may read. A conversation already running keeps the old one, so it ends and the next message starts fresh.
    public func setRepositoryPath(_ path: String) {
        let cleaned = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned != repositoryPath else { return }
        repositoryPath = cleaned
        defaults.set(cleaned, forKey: Self.defaultsKey)
        // What the agents learned is about the old repository.
        memory = AgentMemory()
        saveMemory()
        if handle != nil {
            endConversation()
            notice(cleaned.isEmpty ? "Repository cleared. The next message starts a new conversation." : "Repository changed to \(cleaned). The next message starts a new conversation.")
        }
    }

    // MARK: Conversation

    public var isConversationActive: Bool { handle != nil }

    public func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy else { return }
        guard repositoryStatus.isReady else {
            messages.append(AgentChatMessage(kind: .error, agent: "", text: "Choose a local repository first (Settings, or the Repository button above)."))
            return
        }
        if handle == nil, !launchAgent() { return }
        if conversationTitle == ConversationSummary.untitled { conversationTitle = Self.title(from: text) }
        messages.append(AgentChatMessage(kind: .user, agent: "", text: text))
        memory.turns.append(AgentMemory.Turn(user: text, answer: ""))
        saveMemory()
        sendCount += 1
        isBusy = true
        resetStatuses()
        usage = AgentUsage()
        write(["t": "user", "text": text])
    }

    /// The approval card: answer a question the agents asked the person.
    public func answer(_ reply: String) {
        guard let prompt else { return }
        write(["t": "answer", "id": prompt.id, "text": reply])
        self.prompt = nil
    }

    public func stop() {
        endConversation()
        notice("Stopped.")
    }

    /// Asks to clear the conversation: the view shows a confirmation first, because clearing also makes the agents forget what they learned.
    public func requestClear() {
        guard hasMessages else { return }
        isConfirmingClear = true
    }

    public func cancelClear() { isConfirmingClear = false }

    public func clear() {
        isConfirmingClear = false
        endConversation()
        messages = []
        lastCaseKey = ""
        cases = [:]
        conversationTitle = ConversationSummary.untitled
        memory = AgentMemory()
        saveMemory()
    }

    private func launchAgent() -> Bool {
        do {
            let run = try launcher.launch(arguments: ["--agent", "--events", "--repo=\(repositoryPath)", "--provider=\(provider)"] + (flow == .full ? [] : flow.jsonString.map { ["--flow=\($0)"] } ?? []))
            handle = run
            // A new agent process knows nothing: remind it of the earlier turns and what was learned, before the first message.
            if !memory.isEmpty, let data = try? JSONEncoder().encode(memory), let text = String(data: data, encoding: .utf8) {
                write(["t": "memory", "text": text])
            }
            Task { [weak self] in
                for await line in run.lines { self?.consume(line) }
                self?.processEnded(run)
            }
            return true
        } catch {
            messages.append(AgentChatMessage(kind: .error, agent: "", text: error.localizedDescription))
            return false
        }
    }

    private func endConversation() {
        answerDevice(.deny)
        closeOpenTurn("(stopped before it finished)")
        handle?.terminate()
        handle = nil
        isBusy = false
        prompt = nil
        closeOpenMessages()
        resetStatuses()
    }

    private func processEnded(_ run: any CaseRunHandle) {
        guard handle === run else { return }
        handle = nil
        if isBusy {
            messages.append(AgentChatMessage(kind: .error, agent: "", text: "The agent process ended unexpectedly. Your next message continues with what it had learned."))
            closeOpenTurn("(the agent process ended before it finished)")
        }
        isBusy = false
        prompt = nil
        closeOpenMessages()
        resetStatuses()
    }

    func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object), let line = String(data: data, encoding: .utf8) else { return }
        handle?.send(line)
    }

    private func notice(_ text: String) {
        messages.append(AgentChatMessage(kind: .notice, agent: "", text: text))
    }

    /// Feeds recorded `@@EVENT` lines through the same path as a live run, at about `eventsPerSecond` (harness for long conversations).
    public func replay(lines: [String], eventsPerSecond: Int) async {
        // A replay is a harness: nothing it shows is ever saved, not even by a save that was already scheduled.
        persistsMemory = false
        messages.append(AgentChatMessage(kind: .user, agent: "", text: "(replayed conversation)"))
        isBusy = true
        var sent = 0
        for line in lines {
            consume(line)
            sent += 1
            if sent % max(1, eventsPerSecond / 10) == 0 { try? await Task.sleep(nanoseconds: 100_000_000) }
        }
        // A replay that ends on a pending question leaves the chat waiting for it, as a live run would.
        if prompt == nil { isBusy = false }
    }

    // MARK: Events

    func consume(_ line: String) {
        guard line.hasPrefix("@@EVENT "), let data = line.dropFirst(8).data(using: .utf8),
              let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let type = event["t"] as? String else { return }
        let agent = event["agent"] as? String ?? ""
        switch type {
        case "agent-ready":
            modelName = event["model"] as? String ?? ""
        case "agent-start":
            setPhase(agent, .working, role: event["role"] as? String)
        case "agent-think":
            stream(.thinking, agent: agent, delta: event["delta"] as? String ?? "")
        case "agent-text":
            stream(.text, agent: agent, delta: event["delta"] as? String ?? "")
        case "agent-usage":
            usage.input = event["totalInput"] as? Int ?? usage.input
            usage.output = event["totalOutput"] as? Int ?? usage.output
            usage.cached = event["totalCached"] as? Int ?? usage.cached
        case "agent-turn-end":
            closeOpenMessages()
        case "agent-tool":
            closeOpenMessages()
            var message = AgentChatMessage(kind: .tool, agent: agent, text: event["args"] as? String ?? "")
            message.callID = event["id"] as? String ?? ""
            message.toolName = event["name"] as? String ?? ""
            message.isOpen = true
            messages.append(message)
        case "agent-tool-result":
            if let index = messages.lastIndex(where: { $0.kind == .tool && $0.callID == (event["id"] as? String ?? "") }) {
                messages[index].result = event["summary"] as? String ?? ""
                messages[index].succeeded = event["ok"] as? Bool ?? true
                messages[index].milliseconds = event["ms"] as? Int
                messages[index].endedAt = Date()
                messages[index].isOpen = false
            }
        case "agent-handoff":
            closeOpenMessages()
            let target = event["to"] as? String ?? ""
            var handoff = AgentChatMessage(kind: .handoff, agent: event["from"] as? String ?? "", text: event["task"] as? String ?? "")
            handoff.toolName = target
            messages.append(handoff)
            setPhase(target, .working, role: nil)
        case "agent-return":
            setPhase(event["from"] as? String ?? "", .done, role: nil)
        case "agent-case":
            guard let info = AgentCaseInfo.parse(event) else { break }
            closeOpenMessages()
            var card = AgentChatMessage(kind: .testCase, agent: "CaseAuthor", text: info.title)
            card.caseInfo = info
            messages.append(card)
            cases[info.key] = info
            lastCaseKey = info.key
            if let data = try? JSONEncoder().encode(info), let json = String(data: data, encoding: .utf8) { mergeFacts(["case.json": json]) }
        case "agent-memory":
            mergeFacts(event["facts"] as? [String: String] ?? [:])
        case "agent-device-request":
            handleDeviceRequest(event)
        case "agent-run-request":
            startRun(key: event["key"] as? String ?? "", bundleID: event["bundleID"] as? String ?? "", fromStep: event["fromStep"] as? Int ?? 1)
        case "prompt":
            prompt = AgentPrompt(id: event["id"] as? String ?? "", title: event["title"] as? String ?? "Approval", message: event["message"] as? String ?? "",
                                 caseKey: event["caseKey"] as? String)
        case "prompt-done":
            if prompt?.id == event["id"] as? String { prompt = nil }
        case "agent-final":
            closeOpenMessages()
            let verdict = event["verdict"] as? String ?? "NONE"
            lastCaseKey = event["caseKey"] as? String ?? ""
            if let last = memory.turns.indices.last {
                memory.turns[last].answer = String((event["answer"] as? String ?? "").prefix(AgentMemory.maxAnswerCharacters))
                if memory.turns[last].answer.isEmpty { memory.turns[last].answer = "(done)" }
            }
            mergeFacts(event["facts"] as? [String: String] ?? [:])
            saveMemory()
            usage = AgentUsage(input: event["input"] as? Int ?? usage.input, output: event["output"] as? Int ?? usage.output, cached: event["cached"] as? Int ?? usage.cached,
                               seconds: event["seconds"] as? Int ?? 0, calls: event["calls"] as? Int ?? 0)
            if verdict != "NONE" || !lastCaseKey.isEmpty {
                messages.append(AgentChatMessage(kind: .verdict, agent: "Orchestrator", text: verdict))
            }
            setPhase("Orchestrator", .done, role: nil)
            isBusy = false
            // The end of a turn is saved at once, with its verdict, rather than waiting for the delayed save.
            persistNow()
        case "agent-error":
            closeOpenMessages()
            messages.append(AgentChatMessage(kind: .error, agent: "", text: event["message"] as? String ?? "The agents stopped."))
            closeOpenTurn("(failed: \(event["message"] as? String ?? "the agents stopped"))")
            isBusy = false
        default: break
        }
    }

    private func stream(_ kind: AgentChatMessage.Kind, agent: String, delta: String) {
        if let last = messages.last, last.kind == kind, last.agent == agent, last.isOpen {
            messages[messages.count - 1].text += delta
        } else {
            closeOpenMessages()
            var message = AgentChatMessage(kind: kind, agent: agent, text: delta)
            message.isOpen = true
            messages.append(message)
        }
    }

    private func closeOpenMessages() {
        // Only touch the array when something is open: every write schedules a redraw.
        guard messages.contains(where: { $0.isOpen && $0.kind != .tool }) else { return }
        for index in messages.indices where messages[index].isOpen && messages[index].kind != .tool {
            messages[index].isOpen = false
            messages[index].endedAt = Date()
        }
    }

    private func setPhase(_ name: String, _ phase: AgentStatus.Phase, role: String?) {
        guard let index = agents.firstIndex(where: { $0.id == name }) else { return }
        agents[index].phase = phase
        if let role { agents[index].role = role }
    }

    private func resetStatuses() {
        for index in agents.indices { agents[index].phase = .idle }
    }

    // MARK: Test runs

    /// Where a saved case lives.
    public func caseFileURL(_ key: String) -> URL { projectRoot.appendingPathComponent("TestCases/\(key).json") }

    public func caseFileExists(_ key: String) -> Bool { FileManager.default.fileExists(atPath: caseFileURL(key).path) }

    /// The saved case file's text, for copying.
    public func caseFileText(_ key: String) -> String? { try? String(contentsOf: caseFileURL(key), encoding: .utf8) }

    /// Runs a saved case from its card. The person's own click is the approval, exactly as starting it from the Run section.
    public func runNow(_ info: AgentCaseInfo) {
        guard let caseRun, !caseRun.isRunning, !isBusy else { return }
        // The runner finds a case by its file; without it the run would end at once and show nothing.
        guard caseFileExists(info.key) else {
            notice("TestCases/\(info.key).json does not exist (it was deleted or never saved), so it cannot be run. Ask the agents to write the case again.")
            return
        }
        caseRun.start(key: info.key, bundleID: info.bundleID.isEmpty ? nil : info.bundleID)
        if caseRun.isRunning { workspace?.show(.run) } else if let error = caseRun.errorMessage { notice("Could not start the run: \(error)") }
    }

    public var canRunCases: Bool { !(caseRun?.isRunning ?? true) && !isBusy }

    /// The agents asked for a run (the person approved it in the chat). It runs in the Run section so its prompts and live view work as usual.
    private func startRun(key: String, bundleID: String, fromStep: Int = 1) {
        guard let caseRun, !key.isEmpty else { write(["t": "run-result", "text": "The app could not start the run."]); return }
        guard !caseRun.isRunning else { write(["t": "run-result", "text": "Another run is already in progress; wait for it to finish."]); return }
        // Continuing from a step keeps the results of the steps before it, when they are the same case's.
        let keeping = fromStep > 1 && caseRun.caseKey == key.uppercased() ? caseRun.steps.filter { $0.id < fromStep } : []
        caseRun.start(key: key, bundleID: bundleID.isEmpty ? nil : bundleID, startStep: fromStep > 1 ? fromStep : nil, keeping: keeping)
        guard caseRun.isRunning else {
            write(["t": "run-result", "text": "The run could not start: \(caseRun.errorMessage ?? "unknown error")"])
            return
        }
        workspace?.show(.run)
        let conversation = activeConversationID
        Task { [weak self] in
            while caseRun.isRunning { try? await Task.sleep(nanoseconds: 700_000_000) }
            // The person may have moved to another chat while the run was going; its result belongs to the chat that asked.
            guard let self, self.activeConversationID == conversation else { return }
            self.write(["t": "run-result", "text": Self.summary(of: caseRun)])
            if self.workspace?.section == .run { self.workspace?.show(.agent) }
        }
    }

    static func summary(of run: CaseRunState) -> String {
        var lines = ["Case \(run.caseKey): \(run.title)", "Outcome: \(run.outcome ?? "STOPPED")"]
        for step in run.steps {
            var line = "Step \(step.id) [\(step.status.rawValue)]: \(step.text)"
            if let reason = step.failureReason, !reason.isEmpty { line += " — \(reason)" }
            lines.append(line)
        }
        if let error = run.errorMessage { lines.append("Error: \(error)") }
        if let failed = run.failedStep { lines.append("The run stopped at step \(failed). To continue from it, call run_case with from_step=\(failed): the app is still on the screen that step left.") }
        return lines.joined(separator: "\n")
    }
}
