import Foundation

extension Engine {
    /// One line the macOS app reads: `@@EVENT {json}`. Only printed with `--events`; the ordinary log is unchanged.
    static var emitsEvents = false

    static func emit(_ event: [String: Any]) {
        guard emitsEvents, let data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        print("@@EVENT \(text)")
        fflush(stdout)
    }

    /// What the runner is doing right now, in words: one line the app shows live ("Planning the next action with the fast model"). `kind` is one of
    /// observe, plan, act, settle, judge, check, replay, recovery, code, wait.
    static func activity(step: Int, kind: String, _ text: String) {
        emit(["t": "activity", "step": step, "kind": kind, "text": text])
    }

    /// A step of the case begins, is retried, or ends. The app shows the current step from these, not by guessing from the rows.
    static func stepState(_ number: Int, _ state: String, attempt: Int = 1) {
        emit(["t": "step", "number": number, "state": state, "attempt": attempt])
    }

    /// A line of the runner's reasoning for a step: what it saw, planned, did, was told by the judge, and decided. `kind` is observe, plan, act,
    /// judge, decide, check, code or recovery.
    static func reasoning(step: Int, kind: String, _ text: String) {
        emit(["t": "think", "step": step, "phase": kind, "text": text])
    }

    /// Asks the person running the case for a value and reads the answer from stdin (the app writes it there, so a password never
    /// touches a file). Returns nil when nobody answers within `ATA_USER_WAIT_SECONDS` (ten minutes by default).
    static func ask(id: String, kind: String, title: String, message: String, secure: Bool) -> String? {
        let limit = CaseRunSession.personWaitSeconds
        emit(["t": "activity", "kind": "wait", "text": "Waiting for you: \(title) (\(Int(limit)) s)"])
        emit(["t": "prompt", "id": id, "kind": kind, "title": title, "message": message, "secure": secure, "timeout": Int(limit)])
        let answer = StdinAnswers.shared.next(timeout: limit)
        emit(["t": "prompt-done", "id": id])
        if answer == nil { print(">>> No answer to \"\(title)\" within \(Int(limit)) s.") }
        return answer
    }
}

/// One reader of stdin for the whole process, so a question that timed out does not leave a second reader behind to swallow the next answer.
/// A line that starts `@@NOTE ` (the app) or `note:` (a person at the terminal) is an instruction for the running case, never an answer: it goes
/// to its own queue, so a note typed while the run asks for a password is not taken for the password.
final class StdinAnswers: @unchecked Sendable {
    static let shared = StdinAnswers()
    private let lock = NSLock()
    private var lines: [String?] = []
    private var notes: [String] = []
    private let arrived = DispatchSemaphore(value: 0)
    private var started = false

    /// Starts reading now, so notes are heard while the run is between questions.
    func start() {
        lock.lock(); defer { lock.unlock() }
        guard !started else { return }
        started = true
        Thread.detachNewThread { [self] in
            var open = true
            while open {
                autoreleasepool {
                    guard let line = readLine(strippingNewline: true) else { open = false; return }
                    if let note = Self.note(in: line) { lock.lock(); notes.append(note); lock.unlock(); return }
                    lock.lock(); lines.append(line); lock.unlock(); arrived.signal()
                }
            }
            lock.lock(); lines.append(nil); lock.unlock(); arrived.signal()   // stdin closed: nobody can answer
        }
    }

    /// The instruction in a line, or nil when the line is an ordinary answer.
    static func note(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for prefix in ["@@NOTE ", "note:", "Note:", "NOTE:"] where trimmed.hasPrefix(prefix) {
            let text = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : String(text)
        }
        return nil
    }

    /// What the person said to the running case since it was last asked.
    func takeNotes() -> [String] {
        lock.lock(); defer { lock.unlock() }
        defer { notes = [] }
        return notes
    }

    /// The next line, or nil on timeout or when stdin has closed.
    func next(timeout: TimeInterval) -> String? {
        start()
        guard arrived.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock(); defer { lock.unlock() }
        return lines.removeFirst()
    }
}

extension Engine {
    /// The instructions the person gave the running case since the last look, as guidance.
    static func takeGuidance() -> RunGuidance {
        let said = StdinAnswers.shared.takeNotes()
        return said.isEmpty ? RunGuidance() : GuidanceParser.parse(said.joined(separator: "\n"))
    }

    /// Asks the person to choose, with the options listed (the app shows a dropdown, the terminal numbers them) or to say something else in words.
    /// Returns the option text for a number or an exact option, otherwise what was typed; nil when nobody answers in time.
    static func askChoice(id: String, title: String, message: String, options: [String]) -> String? {
        let limit = CaseRunSession.personWaitSeconds
        print("\n>>> \(title)\n    \(message)")
        for (index, option) in options.enumerated() { print("    \(index + 1)) \(option)\(index == 0 ? "   (suggested)" : "")") }
        print("    Type a number, or tell the agent what to do. Timeout \(Int(limit)) s.")
        emit(["t": "activity", "kind": "wait", "text": "Waiting for you: \(title) (\(Int(limit)) s)"])
        emit(["t": "prompt", "id": id, "kind": "choice", "title": title, "message": message, "secure": false, "options": options, "timeout": Int(limit)])
        let answer = StdinAnswers.shared.next(timeout: limit)?.trimmingCharacters(in: .whitespacesAndNewlines)
        emit(["t": "prompt-done", "id": id])
        guard let answer, !answer.isEmpty else { return nil }
        if let number = Int(answer), options.indices.contains(number - 1) { return options[number - 1] }
        return answer
    }
}
