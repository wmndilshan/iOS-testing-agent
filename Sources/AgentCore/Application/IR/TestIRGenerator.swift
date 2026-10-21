import Foundation

public enum TestIRGeneratorError: Error, Sendable, Equatable {
    /// The model's response was not a `TestIR` document the strict decoder accepts (wrong schema version,
    /// unknown top-level field, or any nested field that fails `Decodable`, e.g. an unknown `IRAction`).
    case invalidResponse(String)
}

/// Turns one AIO test case's free text into a `TestIR` document via the **existing** LLM infrastructure
/// (`LLMClientProtocol.sendPrompt`) — no
/// second Gemini client, no schema-constrained wire format invented. The model's output is untrusted: this
/// type only decodes it strictly (`TestIR.decode`); `TestIRValidator` is the actual security boundary.
///
/// The prompt is built from data the trusted application already owns (`ToolCatalog.descriptors`,
/// `IOSCapabilityRegistry`), so the model is told the truth about what exists and what is already known to
/// be limited — it is never asked to invent a tool or pretend a documented limitation does not apply.
public struct TestIRGenerator: Sendable {
    public let llmClient: any LLMClientProtocol

    /// Accepts **any** conforming client — including the real `LLMClient(config:)` the rest of the app
    /// already uses (`AppCompositionRoot`, the closed-loop/teardown runners), reading `GEMINI_API_KEY`/
    /// `LLM_API_KEY` via `Configuration.load()`. No second, competing LLM integration exists: this
    /// `Application`-layer type depends only on the `LLMClientProtocol` port, never on a concrete
    /// Infrastructure client — the architecture's own layering rule (`Application` may not import
    /// `Infrastructure`) forbids this file from constructing `LLMClient`/`Configuration` itself, so pointing
    /// generation at the real model is the *caller's* job (proven, without a network call, in
    /// `TestIRGenerationHardeningTests.testRealLLMClientIsADropIn`), not a factory method here.
    public init(llmClient: any LLMClientProtocol) {
        self.llmClient = llmClient
    }

    /// - Parameter vocabulary: When supplied, the exact, deterministic
    ///   real-element vocabulary (`ObservedUIVocabulary.promptBlock()`) is appended to the prompt, and the
    ///   model is told to use ONLY those identifiers. This never widens what is accepted — `TestIR.decode`
    ///   and `TestIRValidator` are unchanged — it only gives the model real data to ground against instead
    ///   of guessing. `nil` (the default) preserves the exact prior prompt text byte-for-byte, so every
    ///   existing caller/test is unaffected.
    /// - Parameter groundingFeedback: Bounded regeneration feedback. When a prior attempt's IR had an
    ///   unresolved/ambiguous/unsupported target, the caller may pass a short, secret-free description of
    ///   what was wrong (never raw driver/authorization/host data — see
    ///   `ObservationGroundingFeedback.build(from:)`), asking the model to regenerate against the same
    ///   vocabulary. This is generation correction only — it never re-executes anything.
    /// - Parameter onRawResponse: optional diagnostic hook receiving the model's raw text verbatim, before
    ///   extraction/decode — used only by the opt-in live smoke-test CLI to report *why* a real response
    ///   failed to decode (never used by any test; never changes what is accepted).
    public func generate(testKey: String, title: String, stepsText: String, vocabulary: ObservedUIVocabulary? = nil,
                         groundingFeedback: String? = nil, onRawResponse: (@Sendable (String) -> Void)? = nil) async throws -> TestIR {
        let prompt = Self.prompt(testKey: testKey, title: title, stepsText: stepsText, vocabulary: vocabulary, groundingFeedback: groundingFeedback)
        let raw = try await llmClient.sendPrompt(prompt)
        onRawResponse?(raw)
        guard let data = Self.extractJSON(from: raw), let ir = TestIR.decode(data) else {
            throw TestIRGeneratorError.invalidResponse("Model response was not a valid TestIR document (schemaVersion \(TestIR.currentSchemaVersion)).")
        }
        return DirectionNormalizer.normalized(ir)
    }

    /// Real LLM responses are frequently one of: a bare JSON object, a ```json fenced block, or a fenced/bare
    /// object with conversational prose before and/or after it ("Here is the IR:\n```json\n{...}\n```\nLet
    /// me know if you'd like changes."). This locates the JSON payload in all three shapes without ever
    /// executing or interpreting the surrounding text as anything but noise to discard. It never widens what
    /// is accepted as *safe*: the extracted substring still goes through `TestIR.decode`'s strict schema and
    /// field-set checks unchanged, so tolerating chattier responses cannot admit anything unsafe it wouldn't
    /// already reject.
    static func extractJSON(from raw: String) -> Data? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fenceRange = text.range(of: "```") {
            var afterFence = text[fenceRange.upperBound...]
            if let firstLineEnd = afterFence.firstIndex(of: "\n"), afterFence[afterFence.startIndex..<firstLineEnd].allSatisfy({ $0.isLetter }) {
                afterFence = afterFence[afterFence.index(after: firstLineEnd)...]
            }
            if let closingFence = afterFence.range(of: "```") {
                text = String(afterFence[..<closingFence.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else if let firstBrace = text.firstIndex(of: "{"), let lastBrace = text.lastIndex(of: "}"), firstBrace < lastBrace {
            // No fence at all, but the object may still be wrapped in conversational prose.
            text = String(text[firstBrace...lastBrace])
        }
        return text.data(using: .utf8)
    }

    static func prompt(testKey: String, title: String, stepsText: String, vocabulary: ObservedUIVocabulary? = nil, groundingFeedback: String? = nil) -> String {
        let toolNames = ToolCatalog.descriptors.map(\.name).sorted().joined(separator: ", ")
        let actionNames = IRAction.allCases.map(\.rawValue).joined(separator: ", ")
        let vocabularySection = vocabulary.map { "\n\n\($0.promptBlock())\n\nThe illustrative examples above (e.g. \"status_label\", \"username_field\", \"ALPHA\") are shape samples ONLY — never copy an example's literal identifier into your output. Every identifier/label you actually use for an element-specific target, condition, or signal MUST appear in the CURRENT OBSERVED UI VOCABULARY above, or you must represent the limitation explicitly (per the AIO rules below) instead of fabricating one." } ?? ""
        let feedbackSection = groundingFeedback.map { "\n\nREGENERATION REQUIRED — a prior attempt proposed a target that does not exist in the current observation:\n\($0)\nRegenerate the full TestIR document using only identifiers from the vocabulary above." } ?? ""
        return """
        You convert one AIO manual/automated test case into a TestIR JSON document. You do not execute \
        anything; you only produce data that a separate, deterministic validator and compiler will check \
        before anything ever runs on a device.

        Test key: \(testKey)
        Title: \(title)

        AIO steps:
        \(stepsText)

        Rules:
        - Output ONLY a single JSON object matching the TestIR schema below. No prose, no markdown fences.
        - "schemaVersion" must be \(TestIR.currentSchemaVersion).
        - Every "action" must be one of: \(actionNames). Do not invent a new action name.
        - An action's underlying device tool is one of: \(toolNames). You never name a tool directly; the \
          action implies it.
        - CRITICAL: every step whose action is tap, doubleTap, longPress, typeText, clearText, navigateBack, \
          selectTab, dismissKeyboard, or getElementDetails MUST include a non-null "target" identifying the \
          specific element to act on (e.g. the actual back button, not just the concept of "going back") — \
          even when the AIO wording sounds generic like "navigate back" or "dismiss the keyboard". A step \
          with one of these actions and a null/missing "target" is always rejected.
        - Decompose a compound AIO step (e.g. "create a collection") into a sequence of IRStep primitives, \
          each carrying the same "sourceStepNumber" as the AIO step it came from.
        - Never include a password or other credential value anywhere in the document. When an AIO step's \
          Test Data is a credential, set "credentialRef" to a short, ALL_CAPS symbolic name only (e.g. \
          "TEST_USER_PASSWORD") and omit any literal value for that field.
        - When an AIO step says "if X does not already exist, create it", represent it as one IRStep whose \
          "branch" has a condition of kind elementExists, with "thenSteps" (select existing) and "elseSteps" \
          (create it).
        - CRITICAL: any IRStep that carries a "branch" is a pure decision node, never a device action — its \
          own "action" MUST be "verifyOnly" and it MUST NOT have a "target". This applies no matter what the \
          condition is checking (including applicationStateIs/appState-flavored conditions) — the actual \
          check happens inside "condition", not via the step's own action. A branch step with any other \
          action (e.g. "appState", "tap") is always rejected.
        - CRITICAL: pick the branch "condition" kind to match the exact property the AIO wording names — \
          do not default to elementExists for everything. "exists"/"is present"/"is visible" -> elementExists/ \
          elementNotExists. "is already selected"/"is active"/"is the current tab" -> elementSelected (NOT \
          elementExists — a tab can exist without being the selected one). "is enabled"/"is disabled" -> \
          elementEnabled. "shows the text X"/"already contains X" -> elementHasText (NOT elementExists — an \
          element can exist with the wrong text in it). "the app is running/in the foreground/in the \
          background" -> applicationStateIs (NOT elementExists — never approximate app-level state with an \
          arbitrary on-screen element as a proxy, even if one is available). Using elementExists for a \
          selection/enabled/text/app-state question is a real, previously observed mistake and is always \
          wrong.
          "elementHasText" wire format has TWO fields — the target under "_0" and the text under "equals" \
          (never "text"): {"elementHasText": {"_0": {"role": "textField", "identifier": "search_field"}, \
          "equals": "MSFT"}}
          "applicationStateIs" wire format: {"applicationStateIs": {"_0": "runningForeground"}} — the only \
          valid values are runningForeground, runningBackground, notRunning, unknown.
        - When an AIO step's expected result claims something the accessibility tree cannot prove (for \
          example that a column stays visually "sticky" while scrolling), still emit the step, but set its \
          verification "unsupportedReason" to a short honest note instead of a normal assertion.
        - Every mutating step should carry a "verification" derived from the AIO step's Expected Result \
          column, using only requiredElements/forbiddenElements/signals (elementExists, elementAppeared, \
          elementDisappeared, labelChanged, labelBecame, valueChanged, selectedBecame, navigationBarBecame, \
          keyboardBecame, foregroundApplication, accessibilitySnapshotChanged).
        - CRITICAL: a "verifyOnly" step checks ONE observation only (it never performs a device action, so \
          there is no "before" and "after" to compare) — its signals may ONLY be "elementExists" or \
          "foregroundApplication" (state checks). NEVER give a verifyOnly step a transition signal \
          (elementAppeared, elementDisappeared, labelChanged, labelBecame, valueChanged, selectedBecame, \
          navigationBarBecame, keyboardBecame) — comparing an observation to itself, such a signal can never \
          hold, and the document will be rejected. A transition signal belongs on the mutating action step \
          that actually causes the change, not on a separate verifyOnly step that checks the result afterward \
          — use "elementExists" on the verifyOnly step instead (e.g. "verify the tab is selected" -> a \
          verifyOnly step with elementExists on the tab, or check requiredElements' state, not selectedBecame).
        - CRITICAL: "signals" (ObservationSignal) and "condition" (IRCondition) are two DIFFERENT closed \
          vocabularies that happen to share some names — do not use a condition-only name as a signal. \
          "elementEnabled", "elementSelected", "elementNotExists", "elementHasText", "applicationStateIs" \
          are CONDITION kinds only (used inside "branch"/"condition") and are NEVER valid inside "signals" — \
          using one there is always rejected. There is no "became enabled"/"became disabled" TRANSITION \
          signal at all: to verify an element's enabled state changed (e.g. "the button becomes disabled \
          after submitting"), do NOT put anything about "enabled" in the mutating step's "signals" — instead \
          add a separate verifyOnly step afterward whose "requiredElements" entry sets "requireEnabled": \
          false (or true) on that element; requireEnabled/requireHittable/requireNonZeroBounds are STATE \
          checks against a single observation, exactly what verifyOnly can honestly check.
        - CRITICAL wire format for "condition" (IRCondition) and each entry of "signals" (ObservationSignal): \
          these decode as Swift enums, encoded as a single-key object whose key is EXACTLY the case name \
          (never a "kind"/"type" discriminator field). If the case has exactly one unlabeled value, nest it \
          under the literal key "_0". If the case has one labeled value, use that label as the key. Study \
          this real, machine-verified example carefully and copy its shape exactly:
          {
            "action": "verifyOnly", "arguments": {},
            "branch": {
              "condition": {"elementExists": {"_0": {"role": "button", "label": "Test1"}}},
              "thenSteps": [{"id": "s-then", "sourceStepNumber": 15, "intent": "select existing", "action": "tap",
                             "target": {"role": "button", "label": "Test1"}, "arguments": {},
                             "verification": {"description": "Test1 active", "requiredElements": [], "forbiddenElements": [],
                                              "signals": [{"selectedBecame": {"_0": {"role": "button", "label": "Test1"}}}]}}],
              "elseSteps": []
            }
          }
          Another signal example (a LABELED single value uses its label, not "_0"):
          {"foregroundApplication": {"bundleID": "com.example.app"}}
          And a composed condition (all/any/not each wrap a "_0" array or nested condition the same way):
          {"all": {"_0": [{"elementExists": {"_0": {"role": "button", "label": "A"}}}, {"elementEnabled": {"_0": {"role": "button", "label": "A"}}}]}}
          CRITICAL: "labelChanged", "labelBecame" and "valueChanged" take a PLAIN STRING identifier, never an \
          object with role/label — do not confuse these with "elementExists"/"selectedBecame", which take a \
          full locator object. Copy these exactly:
          {"labelChanged": {"identifier": "username_field"}}
          {"labelBecame": {"identifier": "status_label", "to": "Connected"}}
          {"valueChanged": {"identifier": "collection_name_field"}}
          CRITICAL: "navigationBarBecame" also takes a PLAIN STRING under the label "identifier" — never \
          "title" and never "_0". Copy this exactly:
          {"navigationBarBecame": {"identifier": "ALPHA"}}
          "keyboardBecame" takes a PLAIN BOOL under the label "visible": {"keyboardBecame": {"visible": true}}
        - CRITICAL: every object inside "requiredElements"/"forbiddenElements" MUST include all six fields, \
          every time, even when using the defaults shown — the decoder has no defaults of its own and \
          rejects the object if any is missing: \
          {"role": "staticText", "identifier": null, "label": "Settings", "requireNonZeroBounds": true, \
          "requireEnabled": false, "requireHittable": false}

        - When the AIO text names a CONTAINING element for a target ("the ALPHA row INSIDE the Collection \
          items container", "the + button belonging to the MSFT result"), add "within" to that target: \
          {"role": "cell", "label": "ALPHA", "within": {"role": "scrollView", "label": "Collection Items"}}. \
          "within" only ever has role/identifier/label (never its own nested "within") and, like any other \
          target, needs an identifier or label to be usable — a bare-role scope is rejected exactly like a \
          bare-role target. Only add "within" when the AIO text actually names a container; do not invent one.

        TestIR schema (informal): { schemaVersion, testKey, title, steps: [ { id, sourceStepNumber, intent, \
        action, target?: {role, identifier?, label?, within?: {role, identifier?, label?}}, arguments: {..} \
        (always present, {} if empty), credentialRef?, wait?: {target, timeoutSeconds}, \
        branch?: {condition, thenSteps, elseSteps}, \
        verification?: {description, requiredElements, forbiddenElements, signals, unsupportedReason?} } ] }
        """ + vocabularySection + feedbackSection
    }
}
