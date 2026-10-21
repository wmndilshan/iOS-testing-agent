import Foundation
import AgentCore
import AgentInfrastructure

/// The words the planner is given besides the step itself, and the way a case step is split into action and expected result.
enum PlannerNotes {
    /// What the idb accessibility tree can and cannot show, so the planner does not build checks that can never hold.
    static let environment = """
    Environment notes: the screen's accessibility tree records no selected or focused state, so never use selectedBecame or \
    elementSelected. Prefer elementExists for the screen you expect to reach; use elementAppeared only for an element that was certainly \
    absent before the action, since it fails when the element was already there. Several elements can share one identifier \
    (for example every row of a drawer); then target the one you want by its exact label, copied from the element list. Labels \
    can be long composite strings; copy them exactly. To submit typed text (a web address, a search) use the dismissKeyboard action \
    on the field you typed in: it presses the Return key. There is no on-screen keyboard to tap. A target scrolled out of view is brought into view by the runner.
    """

    /// The note for one action round: plan exactly one action, given what is already done and what the judge said was missing.
    static func actionNote(stepText: String, done: [String], judgeFeedback: String?, codeFacts: String? = nil, untypedData: String? = nil) -> String {
        var note = stepText.contains("[CREDENTIALS]") ? "This step types a password: use a typeText action on the secure password field with credentialRef \"TEST_USER_PASSWORD\" and no text argument. " : ""
        note += "Plan exactly ONE action: the next one this screen allows toward the step. The expected result is checked afterwards against the new screen, so verify each action only with an accessibilitySnapshotChanged signal and name no element that is not on the current screen."
        if !done.isEmpty {
            note += " Already done for this step on earlier screens: \(done.joined(separator: "; ")). Plan only what remains; if nothing remains, output a single verifyOnly step."
        }
        // A step with test data ("search for men watches") that has acted on a field but not typed yet: the planner tends to jump to submitting.
        if let untypedData, !done.isEmpty {
            note += " The test data '\(untypedData)' has not been typed yet. Unless all that remains is to submit text that is already in the field, the next action is typeText with that exact text into the focused field, before any submit or Return."
        }
        if let judgeFeedback {
            note += " After those actions the screen was judged NOT to show the expected result: \(judgeFeedback) Plan the one action that moves the screen toward it, and only an action this step asks for. Never change a filter, tab, sort order, setting or selection that this step does not name: later steps depend on the screen staying as it is. If the expected result cannot be reached without such a change (for example the account has no data to show), plan nothing, so the step fails honestly instead of altering the app. If the screen is a dialog or a screen that belongs to a different step (renaming, creating, deleting, saving something this step did not ask for), do not continue it: cancel or close it, or plan nothing."
        }
        if let codeFacts { note += "\n" + codeFacts }
        return note
    }

    static let verifyNote = "Produce ONLY verifyOnly steps (no taps, typing or scrolling) that check exactly what the expected result below says. Never substitute a different element because a named one is missing from the screen: still name the element the expected result describes, and the run will report it as missing. A check of something other than the expected result is wrong."

    /// The question that decides whether another action round is needed.
    static func completenessPrompt(stepText: String, expected: String, done: [String], screenLabels: String) -> String {
        """
        You judge whether the ACTIONS of one UI test step have all been performed. The expected result shows what the actions must \
        lead to: if it describes something that has not happened yet (a setting changed, a value saved), actions still remain.
        Step: \(stepText)
        Expected result: \(expected.isEmpty ? "not stated" : expected)
        Actions already performed, in order: \(done.isEmpty ? "none" : done.joined(separator: "; "))
        Labels on the current screen: \(screenLabels)
        Answer with exactly one word: DONE if every action the step asks for has been performed, or MORE if an action still remains.
        """
    }

    /// An identifier carried by several elements (every row of a drawer, for example) cannot name one of them, so the planner
    /// is shown such elements by label only and cannot build a target that grounding would call ambiguous.
    /// A floating overlay button (the chat bubble that sits over every screen) is not a target for a step that never mentions it:
    /// with a button "that opens the drawer" missing from the screen, the planner would otherwise tap the bubble and leave the flow.
    static func withoutUnrelatedFloaters(_ observation: Observation, for stepText: String) -> Observation {
        let text = stepText.lowercased()
        let floaters = observation.elements.filter { element in
            guard let identifier = element.identifier?.lowercased(), identifier.hasPrefix("floating-") else { return false }
            let words = identifier.dropFirst("floating-".count).split(separator: "-").map(String.init) + [(element.label ?? "").lowercased()]
            return !words.contains { !$0.isEmpty && text.contains($0) } && !(identifier.contains("chat") && (text.contains("zeus") || text.contains("conversation")))
        }
        guard !floaters.isEmpty else { return observation }
        let ids = Set(floaters.map(\.id))
        var copy = Observation(snapshotID: observation.snapshotID, timestamp: observation.timestamp, bundleID: observation.bundleID, appState: observation.appState,
                               source: observation.source, elements: observation.elements.filter { !ids.contains($0.id) }, screenshotPath: observation.screenshotPath, isTruncated: observation.isTruncated)
        copy.application = observation.application
        copy.simulatorUDID = observation.simulatorUDID
        return copy
    }

    static func withoutSharedIdentifiers(_ observation: Observation) -> Observation {
        // Only elements of the SAME role are ambiguous: a text field and its clear button can share one identifier, and a target that names the
        // role (textField) still picks exactly one of them.
        struct Key: Hashable { let role: String; let identifier: String }
        let counts = Dictionary(grouping: observation.elements.compactMap { element in element.identifier.flatMap { $0.isEmpty ? nil : Key(role: element.role, identifier: $0) } }, by: { $0 }).mapValues(\.count)
        let elements = observation.elements.map { element -> UIElementSnapshot in
            guard let identifier = element.identifier, counts[Key(role: element.role, identifier: identifier), default: 0] > 1 else { return element }
            return UIElementSnapshot(id: element.id, parentID: element.parentID, role: element.role, label: element.label, identifier: nil, value: element.value,
                                     placeholderValue: element.placeholderValue, isEnabled: element.isEnabled, isHittable: element.isHittable,
                                     isSelected: element.isSelected, hasFocus: element.hasFocus, isSecure: element.isSecure, depth: element.depth, frame: element.frame)
        }
        var copy = Observation(snapshotID: observation.snapshotID, timestamp: observation.timestamp, bundleID: observation.bundleID, appState: observation.appState,
                               source: observation.source, elements: elements, screenshotPath: observation.screenshotPath, isTruncated: observation.isTruncated)
        copy.application = observation.application
        copy.simulatorUDID = observation.simulatorUDID
        return copy
    }
}

extension StepText {
    /// "Handle the permission dialog if it appears", "dismiss any drawers": a step whose work depends on something that may not be there.
    static func isConditional(_ stepText: String) -> Bool {
        stepText.range(of: #"\b(if (it|they|one|any|a|an|the|there)\b[^.]{0,40}\b(appear|appears|show|shows|shown|present|displayed|prompted|visible|needed|exist|exists|is|are)\b|if (present|needed|necessary|prompted|shown|displayed|any)\b|(dismiss|handle|close|accept|allow) any\b)|\(optional\)"#,
                       options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The text a step says to type: its `Test Data: ...` sentence, unless that is a placeholder for a secret or empty.
    static func testData(in stepText: String) -> String? {
        guard let range = stepText.range(of: #"Test Data: .*?(?=\. Expected:|\.?$)"#, options: .regularExpression) else { return nil }
        let value = String(stepText[range]).dropFirst("Test Data: ".count).trimmingCharacters(in: .whitespaces)
        return value.isEmpty || value.contains("[CREDENTIALS]") ? nil : value
    }
}

/// A case step split into what to do and what to expect: "<action> Expected: <result>".
struct StepText: Equatable {
    let action: String
    let expected: String
    /// A step that only checks something ("Validate ...", "Verify ...") has no action round.
    let verifiesOnly: Bool
    /// "Verify the options are present, then tap one": the check is about the screen BEFORE the action, so it is made first. After the
    /// action the screen has moved on (the sheet closed), and a check of the earlier screen can no longer hold.
    let verifyThenAct: VerifyThenAct?

    struct VerifyThenAct: Equatable {
        /// The part to check before acting, as a sentence ("Verify the three filter options are present").
        let check: String
        /// The part to do, with the check left out ("tap the option ...").
        let act: String
    }

    private static let actionStems = ["scroll", "swipe", "swiping", "tap", "click", "typ", "enter", "open", "select", "drag", "press", "navigat", "toggl", "pull", "double"]
    private static let checkWords = ["validate", "verify", "confirm", "check", "ensure"]
    private static let verifyThen = try! NSRegularExpression(pattern: #"^((?:validate|verify|confirm|check|ensure)\b.+?)(?:,|;)?\s+(?:and\s+)?then\s+(.+)$"#, options: [.caseInsensitive, .dotMatchesLineSeparators])

    private static func namesAction(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return actionStems.contains { lowered.range(of: "\\b\($0)\\w*", options: .regularExpression) != nil }
    }

    init(_ text: String) {
        let parts = text.components(separatedBy: " Expected: ")
        // "... and wait for the action button" describes the result, not an action; the runner waits for the screen to settle.
        let cleaned = parts[0].replacingOccurrences(of: #"(?i)(,|\band\b|\bthen\b)?\s*\bwait (for|until)\b[^.]*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let expected = parts.dropFirst().joined(separator: " Expected: ")
        // A check-then-act step: the clause before "then" is the check, and what follows (which must name an action) is the action.
        if let match = Self.verifyThen.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)),
           let checkRange = Range(match.range(at: 1), in: cleaned), let actRange = Range(match.range(at: 2), in: cleaned),
           Self.namesAction(String(cleaned[actRange])), !Self.namesAction(String(cleaned[checkRange])) {
            let act = String(cleaned[actRange]).trimmingCharacters(in: .whitespaces)
            action = act
            self.expected = expected
            verifiesOnly = false
            verifyThenAct = VerifyThenAct(check: String(cleaned[checkRange]).trimmingCharacters(in: .whitespaces), act: act)
            return
        }
        action = cleaned
        self.expected = expected
        verifyThenAct = nil
        // "Check grid view by scrolling horizontally" starts like a check but asks for a scroll: a step is read-only only when it names no action.
        verifiesOnly = Self.checkWords.contains { cleaned.lowercased().hasPrefix($0) } && !Self.namesAction(cleaned)
    }

    /// The expected result as the judge sees it after the action. For a check-then-act step, what was visible before the action was already
    /// checked and may be gone, so the judge is told to look only at what the action should have left on screen.
    var expectedAfterAction: String {
        guard verifyThenAct != nil, !expected.isEmpty else { return expected }
        return expected + " (Anything above about what was visible BEFORE the action was checked before it and may no longer be on screen; judge what the action should have left on screen.)"
    }

    /// A step that asks for several things in sequence ("tap the field and search for X"). A single-action step is simple enough for
    /// the fast model; a compound one goes straight to the strong model, because a wrong first plan leaves the screen in a state
    /// that costs several corrective rounds to recover.
    var isCompound: Bool {
        let lowered = " " + action.lowercased() + " "
        return [" and ", " then ", ", then", " after ", ";"].contains { lowered.contains($0) }
    }
}
