import Foundation
import AgentCore
import AgentInfrastructure

/// Several vision models tried in order. One that reports exhausted quota is set aside for ten minutes (and remembered between runs, so the next
/// run does not wait for it again); one that is overloaded for a minute. A slow answer only moves this call on to the next model.
@MainActor
final class JudgePool {
    struct Unavailable: Error { let reason: String }
    private let clients: [(model: String, client: LLMClient)]
    private var setAside: [String: (reason: String, until: Date)] = [:]
    private let memoryURL: URL?
    /// The most one judgement may spend walking down the list of models.
    private let budget: TimeInterval = 45

    init(models: [(String, LLMClient)], memoryURL: URL? = nil) {
        clients = models.map { (model: $0.0, client: $0.1) }
        self.memoryURL = memoryURL
        if let memoryURL, let data = try? Data(contentsOf: memoryURL), let saved = try? JSONDecoder().decode([String: Double].self, from: data) {
            for (model, until) in saved where Date(timeIntervalSince1970: until) > Date() { setAside[model] = ("out of quota (remembered from an earlier run)", Date(timeIntervalSince1970: until)) }
        }
    }

    /// The pool for `--judge-models` (or the configured model followed by the fallbacks), or nil without the Gemini configuration.
    /// Free-tier quota is per model, so the judge moves on to the next model when one is out of quota or overloaded.
    static func configured(modelsFlag: String?) -> JudgePool? {
        guard let config = try? Configuration.load() else { return nil }
        // Measured on this task: gemini-3.5-flash-lite answers in about 3 s, gemini-3.1-flash-lite in about 17 s, so the fast one goes first.
        let fallbacks = ["gemini-3.5-flash-lite", "gemini-2.5-flash", "gemini-3.1-flash-lite", "gemini-flash-lite-latest"]
        var names = modelsFlag.map { $0.split(separator: ",").map(String.init) } ?? (fallbacks + [config.model])
        names = names.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        print("Screenshot judge: Gemini models in order \(names.joined(separator: ", ")) (full screenshots are sent to the model).")
        // One session for every quick vision call (the judge and `look`), so connections to the API stay open between them.
        let session = QuickSession.shared
        let memory = WorkingDirectory.url.appendingPathComponent(".runs/judge-models.json")
        return JudgePool(models: names.map { ($0, LLMClient(config: Configuration(apiKey: config.apiKey, model: $0, projectRoot: config.projectRoot), session: session,
                                                                          // One try per model: the next model is the retry.
                                                                          gateway: LLMGateway(transport: URLSessionTransport(session: session), backoffPolicy: BackoffPolicy(initialDelay: 1, maxDelay: 2, maxAttempts: 1), provider: "gemini"))) },
                         memoryURL: memory)
    }

    // MARK: Answers already paid for (this run only)

    private var replies: [String: (reply: String, model: String)] = [:]

    nonisolated static func cacheKey(image: Data, prompt: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in image { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        for byte in prompt.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return "\(image.count)-\(prompt.utf8.count)-\(hash)"
    }

    func cachedReply(_ key: String) -> (String, String)? { replies[key].map { ($0.reply, $0.model) } }

    func storeReply(_ value: (String, String), for key: String) {
        if replies.count >= 40 { replies.removeAll() }
        replies[key] = (value.0, value.1)
    }

    private func isAvailable(_ model: String) -> Bool {
        guard let entry = setAside[model] else { return true }
        if entry.until > Date() { return false }
        setAside[model] = nil
        return true
    }

    private func remember() {
        guard let memoryURL else { return }
        let quota = setAside.filter { $0.value.until.timeIntervalSinceNow > 120 }.mapValues { $0.until.timeIntervalSince1970 }
        try? FileManager.default.createDirectory(at: memoryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(quota).write(to: memoryURL, options: .atomic)
    }

    func complete(_ request: LLMRequest) async throws -> (String, String) {
        let started = Date()
        for (model, client) in clients where isAvailable(model) {
            if Date().timeIntervalSince(started) > budget { break }
            do {
                return (try await client.complete(request), model)
            } catch {
                let text = error.localizedDescription.lowercased()
                let outOfQuota = ["429", "quota", "rate limit", "404", "no longer available"].contains { text.contains($0) }
                let overloaded = ["503", "high demand", "overloaded", "network error", "connection", "offline"].contains { text.contains($0) }
                let slow = text.contains("timed out")
                guard outOfQuota || overloaded || slow else { throw error }
                // A slow model is skipped for a while too (not remembered between runs): otherwise every judgement pays its 15 s timeout first.
                setAside[model] = (slow ? "too slow" : text.prefix(80).description, Date().addingTimeInterval(outOfQuota ? 600 : (slow ? 90 : 60)))
                if outOfQuota { remember() }
                print("  judge model \(model) is \(slow ? "slow" : "not available (\(setAside[model]?.reason ?? ""))"); trying the next one")
            }
        }
        throw Unavailable(reason: "no judge model answered in time or with quota (\(setAside.keys.sorted().joined(separator: ", ")))")
    }
}

extension CaseRunSession {
    /// A vision model looks at the screen and decides whether the expected result is on it. A PASS, and a FAIL on the last attempt,
    /// are recorded as the step's `judge` row with the screenshot as evidence; an earlier FAIL only returns its reason so the
    /// caller can act on it and ask again.
    /// Records the step's final judge failure from a verdict already given, so the last attempt needs no second model call when the screen
    /// has not changed since it was judged. The screenshot of that judgement is the evidence.
    func recordJudgeFailure(number: Int, expected: String, reason: String, attempt: Int) {
        let id = "\(number).judge"
        recordRow(id, number: number, intent: expected, action: "judge", .failed, "judge (attempt \(attempt)): \(reason)")
        attachEvidence(id, path: "\(evidenceDirectory.lastPathComponent)/\(id).png")
    }

    func judgeExpectedResult(_ judge: JudgePool, number: Int, stepText: String, expected: String, done: [String],
                             attempt: Int, isLastAttempt: Bool) async -> (passed: Bool, reason: String) {
        await clock.measure(.judge, "Judging the screen: \(expected.prefix(110))") {
            await judgeOnScreen(judge, number: number, stepText: stepText, expected: expected, done: done, attempt: attempt, isLastAttempt: isLastAttempt)
        }
    }

    private func judgeOnScreen(_ judge: JudgePool, number: Int, stepText: String, expected: String, done: [String],
                               attempt: Int, isLastAttempt: Bool) async -> (passed: Bool, reason: String) {
        let id = "\(number).judge"
        guard let (path, _) = try? await driver.captureScreenshot(reason: id), let png = FileManager.default.contents(atPath: path) else {
            recordRow(id, number: number, intent: expected, action: "judge", .failed, "could not capture a screenshot for the judge")
            return (false, "no screenshot")
        }
        try? FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let destination = evidenceDirectory.appendingPathComponent("\(id).png")
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.moveItem(atPath: path, toPath: destination.path)
        // A screenshot cannot show an item scrolled out of view (a chip in a long row), though the app has it. The labels from the
        // accessibility tree say what exists; scrolled-off ones are marked, so the judge can tell "not there" from "not in the picture".
        var treeNote = ""
        var treeSource = recentObservation()
        if treeSource == nil { treeSource = await observe() }
        if let observation = treeSource { treeNote = Self.treeNote(for: observation) }
        let prompt = """
        You are a strict UI test judge. The image is the current screen of a mobile app.
        Test step: \(stepText)
        Actions performed for this step: \(done.isEmpty ? "none" : done.joined(separator: "; "))
        Expected result: \(expected)
        \(treeNote)
        \(guidance.promptBlock)
        Decide whether the screen clearly shows the expected result; the labels above count as part of the screen. The list of DISABLED controls (when there is one)
        is authoritative about enabled and disabled state: a control on it is disabled, whatever the picture looks like, and a greyed-out control in the picture is disabled too. An item that is listed as
        scrolled out of view exists, but if the expected result says it must be visible, it is not yet visible. Judge only what is visible. A highlighted or outlined option \
        is the selected one. If the screen shows a different screen, a drawer or dialog covering the screen, or an option other than \
        the one expected, or the expected result needs something that is not visible, answer FAIL. For an expected result that something \
        disappears, is hidden or is not shown, it is enough that it is not visible now; you cannot see the earlier screen, so do not ask for it.
        \(StepText.isConditional(stepText) ? "This step is conditional: it only asks for something to be handled if it is there (a dialog, a drawer). When that is not on screen there is nothing to handle, so the step PASSES as long as the app shows a normal screen." : "")
        Reply in exactly two lines:
        VERDICT: PASS or FAIL
        REASON: one sentence naming what you see
        """
        let reply: String
        let model: String
        let started = Date()
        let small = ScreenshotCompressor.jpeg(from: png)
        // The same picture asked the same question (a retry on a screen that did not move) gets the answer already paid for.
        let cacheKey = JudgePool.cacheKey(image: small ?? png, prompt: prompt)
        do {
            if let cached = judge.cachedReply(cacheKey) {
                (reply, model) = cached
            } else {
                (reply, model) = try await judge.complete(LLMRequest(messages: [LLMMessage(text: prompt, imagePNG: small ?? png, imageMIMEType: small == nil ? "image/png" : "image/jpeg")], temperature: 0))
                judge.storeReply((reply, model), for: cacheKey)
            }
        } catch let unavailable as JudgePool.Unavailable {
            // No model can judge right now. That says nothing about the app, so the run is blocked, not failed.
            block("the screenshot judge is unavailable: \(unavailable.reason)")
            recordRow(id, number: number, intent: expected, action: "judge", .skipped, blockedReason ?? "")
            return (false, unavailable.reason)
        } catch {
            let message = "the screenshot judge failed: \(SecretRedactor.redact(error.localizedDescription))"
            recordRow(id, number: number, intent: expected, action: "judge", .failed, message)
            return (false, message)
        }
        // ATA_TRACE_JUDGE=<file> keeps what the judge was asked and what it answered, for working out a verdict that looks wrong.
        if let traceFile = ProcessInfo.processInfo.environment["ATA_TRACE_JUDGE"], !traceFile.isEmpty {
            let entry = "=== step \(number) attempt \(attempt) \(model)\n\(prompt)\n--- reply\n\(reply)\n\n"
            if let handle = FileHandle(forWritingAtPath: traceFile) ?? { FileManager.default.createFile(atPath: traceFile, contents: nil); return FileHandle(forWritingAtPath: traceFile) }() {
                _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(entry.utf8)); try? handle.close()
            }
        }
        let lines = reply.components(separatedBy: "\n")
        let verdict = lines.first { $0.uppercased().contains("VERDICT") }?.uppercased() ?? ""
        let reason = lines.first { $0.uppercased().hasPrefix("REASON") }.map { $0.drop { $0 != ":" }.dropFirst().trimmingCharacters(in: .whitespaces) } ?? reply.prefix(160).description
        let passed = verdict.contains("PASS") && !verdict.contains("FAIL")
        Engine.reasoning(step: number, kind: "judge", "\(passed ? "Looks right" : "Not right") (\(model), \(String(format: "%.1f", Date().timeIntervalSince(started))) s): \(reason)")
        if passed || isLastAttempt {
            recordRow(id, number: number, intent: expected, action: "judge", passed ? .passed : .failed, "judge (attempt \(attempt), \(model), \(String(format: "%.1f", Date().timeIntervalSince(started)))s): \(reason)")
            attachEvidence(id, path: "\(evidenceDirectory.lastPathComponent)/\(id).png")
        } else {
            print("  judge (attempt \(attempt)): not there yet: \(reason)")
        }
        return (passed, reason)
    }
}


extension CaseRunSession {
    /// What the accessibility tree adds to the judge's picture: the labels on screen, those scrolled out of view, and which controls are disabled.
    /// A greyed-out control is easy to misread as enabled in a small picture; the tree knows.
    static func treeNote(for observation: Observation) -> String {
        let named = observation.elements.filter { !$0.isSecure && !($0.label ?? "").isEmpty && ($0.label ?? "").count <= 40 }
        let visible = named.filter(\.isHittable).compactMap(\.label).prefix(70)
        let hidden = named.filter { !$0.isHittable }.compactMap(\.label).prefix(40)
        let disabled = observation.elements.filter { !$0.isEnabled && !$0.isSecure && !(($0.label ?? "").isEmpty && ($0.identifier ?? "").isEmpty) }
            .map { element -> String in
                let name = [element.label, element.identifier].compactMap { $0 }.filter { !$0.isEmpty }
                return name.count == 2 && name[0] != name[1] ? "\(name[0]) (\(name[1]))" : name[0]
            }.prefix(30)
        return "\nAccessibility labels on screen: \(visible.joined(separator: " | "))\nLabels that exist but are scrolled out of view: \(hidden.isEmpty ? "none" : hidden.joined(separator: " | "))\n"
            + (disabled.isEmpty ? "" : "Controls the accessibility tree marks as DISABLED (they are disabled even if they look normal): \(disabled.joined(separator: " | "))\n")
    }
}
