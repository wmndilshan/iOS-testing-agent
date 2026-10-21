import Foundation

/// Drafts `TestSpecification`s from test gaps. The structure (steps, operations, assertion shapes, gates, evidence) is
/// deterministic; concrete inputs and expected values that need reasoning are `<TBD>` with an open question.
public enum TestSpecificationDrafter {

    public struct Options: Sendable {
        /// Also draft specs for behaviors whose coverage is `unverified` (tests exist, evidence unclear).
        public var includeUnverified = false
        public var maxSpecsPerSymbol = 6
        public init() {}
    }

    public static func draft(gaps: [SymbolTestGap], risks: [SymbolID: RiskAssessment], index: ASTIndex, tests: TestIndex, options: Options = .init()) -> [TestSpecification] {
        var sequence: [String: Int] = [:]
        var out: [TestSpecification] = []
        for gap in gaps.sorted(by: { $0.symbol < $1.symbol }) {
            guard let d = index[gap.symbol] else { continue }
            let wanted = gap.behaviors.filter { $0.status == .missing || (options.includeUnverified && $0.status == .unverified) }
            let risk = risks[gap.symbol]?.level ?? .low
            for c in wanted.prefix(options.maxSpecsPerSymbol) {
                let prefix = idPrefix(d)
                let code = categoryCode(c.behavior.category)
                let key = "\(prefix)-\(code)"
                sequence[key, default: 0] += 1
                let id = String(format: "%@-%03d", key, sequence[key]!)
                out.append(spec(id: id, behavior: c.behavior, declaration: d, gap: gap, risk: risk, tests: tests))
            }
        }
        return out
    }

    // MARK: Spec construction

    static func spec(id: String, behavior b: RequiredBehavior, declaration d: Declaration, gap: SymbolTestGap, risk: RiskLevel, tests: TestIndex) -> TestSpecification {
        let TBD = TestSpecification.toBeDetermined
        let target = d.id
        let display = displayName(d)
        let extended = gap.extendableTests.first.flatMap { tests.tests[$0] }
        // Fixtures and mocks from the two best-matching existing tests only: they show what this code is tested with.
        let closest = gap.extendableTests.prefix(2).compactMap { tests.tests[$0] }
        let fixtures = Array(Set(closest.flatMap(\.fixtures))).sorted()
        let mocks = Array(Set(closest.flatMap(\.mocks))).sorted()
        let inputs = d.parameters.map { SpecInput(name: $0.name, value: $0.hasDefault ? "default" : TBD, note: $0.type) }
        let args = Dictionary(d.parameters.map { ($0.name, $0.hasDefault ? "default" : TBD) }, uniquingKeysWith: { a, _ in a })
        let invoke = SpecStep("Invoke \(display)" + (d.isAsync ? " and await it" : "") + ".", OperationRef(name: "invoke", subject: target, arguments: args))
        let result = d.returnType.map { $0 == "Void" ? nil : $0 } ?? nil
        let resultSubject = result != nil ? "result" : "state"

        var preconditions: [String] = []
        if let c = d.container.map(SymbolGraph.simpleName) { preconditions.append("A \(c) constructed with test doubles for its dependencies") }
        var steps: [SpecStep] = []
        var expected: [SpecExpectation] = []
        var cleanup: [SpecStep] = []
        var tools: [String] = []
        var artifacts: [String] = []
        var evidence = ["test run result for this test ID"]
        var questions: [String] = []
        var failure: String?

        func prepare(_ kind: String, _ text: String) { steps.append(SpecStep(text, OperationRef(name: "prepareInput", subject: target, arguments: ["kind": kind, "value": TBD]))) }
        func expectValue(_ what: String) {
            expected.append(SpecExpectation("\(resultSubject.capitalized) equals the expected \(what).", AssertionRef(subject: resultSubject, comparator: .equals, expected: TBD)))
            questions.append("What exact \(resultSubject) should \(display) produce for the \(what)?")
        }
        func expectThrow() {
            let error = d.typedThrows ?? d.body?.thrownTypes.first { $0 != "." } ?? TBD
            expected.append(SpecExpectation("\(display) throws \(error == TBD ? "the documented error" : error).", AssertionRef(subject: "invoke", comparator: .throwsError, expected: error)))
            if error == TBD { questions.append("Which error must \(display) throw for this input?") }
        }
        func expectUnchanged(_ what: String) {
            expected.append(SpecExpectation("\(what.capitalized) is unchanged.", AssertionRef(subject: what, comparator: .unchanged)))
        }
        func expectNotInvoked(_ what: String) {
            expected.append(SpecExpectation("\(what) is never invoked.", AssertionRef(subject: "\(what).invocationCount", comparator: .equals, expected: "0")))
        }

        switch b.id {
        case let id where id.hasPrefix("branch-"):
            let condition = b.summary.components(separatedBy: "`").dropFirst().first ?? "the new condition"
            steps.append(SpecStep("Arrange state/input for which `\(condition)` selects the new path.", OperationRef(name: "arrangeCondition", subject: target, arguments: ["holds": "true", "input": TBD])))
            steps.append(invoke)
            steps.append(SpecStep("Arrange state/input for the opposite outcome of `\(condition)`.", OperationRef(name: "arrangeCondition", subject: target, arguments: ["holds": "false", "input": TBD])))
            steps.append(SpecStep("Invoke \(display) again.", OperationRef(name: "invoke", subject: target, arguments: args)))
            expected.append(SpecExpectation("The new path produces its intended outcome.", AssertionRef(subject: "firstOutcome", comparator: .equals, expected: TBD)))
            expected.append(SpecExpectation("The other path behaves as before the change.", AssertionRef(subject: "secondOutcome", comparator: .equals, expected: TBD)))
            questions.append("What is the intended outcome when `\(condition)` takes the new path?")
            if b.isFailurePath { failure = "When `\(condition)` fails, \(display) refuses without side effects." }
        case "representative", "success", "async-success", "parse-valid", "valid-input", "id-correct", "ui-states", "auth-valid", "retryable":
            prepare("valid", "Prepare valid, representative input.")
            steps.append(invoke)
            if d.isThrows || b.trait == .throwing { expected.append(SpecExpectation("\(display) does not throw.", AssertionRef(subject: "invoke", comparator: .doesNotThrow))) }
            expectValue("valid input")
        case "expected-failure", "invalid-input", "parse-malformed", "id-mismatch", "id-unknown", "ui-stale-error", "failure-path", "security-invariant", "non-retryable":
            let kind = ["parse-malformed": "malformed", "id-mismatch": "mismatchedID", "id-unknown": "unknownID", "ui-stale-error": "staleOrError",
                        "security-invariant": "hostile", "non-retryable": "nonRetryableFailure"][b.id] ?? "invalid"
            prepare(kind, "Prepare \(kind) input.")
            steps.append(invoke)
            if d.isThrows || (d.body?.throwCount ?? 0) > 0 { expectThrow() } else {
                expected.append(SpecExpectation("\(display) reports the failure explicitly.", AssertionRef(subject: resultSubject, comparator: .equals, expected: TBD)))
                questions.append("How does \(display) report this failure (return value, state, error)?")
            }
            if b.id == "non-retryable" { expected.append(SpecExpectation("The operation is attempted exactly once.", AssertionRef(subject: "attemptCount", comparator: .equals, expected: "1"))) }
            failure = "The \(kind) input is rejected; no partial effect is observable."
        case "boundary", "parse-empty", "parse-boundary":
            let kind = b.id == "parse-empty" ? "empty" : "boundary"
            prepare(kind, "Prepare \(kind) input (\(b.id == "parse-empty" ? "empty" : "at the limit, and one past it")).")
            steps.append(invoke)
            expectValue("\(kind) input")
        case "serialization", "suspension-state":
            steps.append(SpecStep("Invoke \(display) concurrently from several tasks.", OperationRef(name: "invokeConcurrently", subject: target, arguments: ["tasks": "8"])))
            steps.append(SpecStep("Await all tasks.", OperationRef(name: "awaitAll")))
            expected.append(SpecExpectation("The final state is consistent (no lost or duplicated updates).", AssertionRef(subject: "state", comparator: .equals, expected: TBD)))
            questions.append("What final state proves the calls were serialized?")
            tools.append("withTaskGroup")
        case "cancellation", "task-cancellation":
            steps.append(SpecStep("Start \(display) in a task.", OperationRef(name: "startTask", subject: target)))
            steps.append(SpecStep("Cancel the task before it completes.", OperationRef(name: "cancelTask")))
            steps.append(SpecStep("Await the task.", OperationRef(name: "awaitTask")))
            expected.append(SpecExpectation("No effect happens after cancellation.", AssertionRef(subject: "effectsAfterCancellation", comparator: .equals, expected: "0")))
            expected.append(SpecExpectation("State is consistent after cancellation.", AssertionRef(subject: "state", comparator: .equals, expected: TBD)))
            questions.append("Which state must remain after cancellation?")
            tools.append("injected clock (no real sleeping)")
        case "valid-transitions":
            steps.append(SpecStep("Put the subject in each source state.", OperationRef(name: "arrangeState", subject: target, arguments: ["state": TBD])))
            steps.append(invoke)
            expected.append(SpecExpectation("The subject reaches the expected next state.", AssertionRef(subject: "state", comparator: .equals, expected: TBD)))
            questions.append("List the (from, event, to) transitions \(display) must support.")
        case "invalid-transitions":
            steps.append(SpecStep("Put the subject in a state where this transition is illegal.", OperationRef(name: "arrangeState", subject: target, arguments: ["state": TBD])))
            steps.append(invoke)
            if d.isThrows { expectThrow() }
            expectUnchanged("state")
            questions.append("Which source states make this transition illegal?")
            failure = "The illegal transition is refused and nothing else changes."
        case "round-trip":
            cleanup.append(SpecStep("Delete the temporary directory.", OperationRef(name: "deleteTemporaryDirectory")))
            steps.append(SpecStep("Create a store in a temporary directory.", OperationRef(name: "createTemporaryDirectory")))
            steps.append(SpecStep("Write a representative value.", OperationRef(name: "persist", subject: target, arguments: ["value": TBD])))
            steps.append(SpecStep("Read it back.", OperationRef(name: "read")))
            expected.append(SpecExpectation("The value read equals the value written.", AssertionRef(subject: "readValue", comparator: .equals, expected: "writtenValue")))
            artifacts.append("temporary store directory")
        case "reopen":
            cleanup.append(SpecStep("Delete the temporary directory.", OperationRef(name: "deleteTemporaryDirectory")))
            steps.append(SpecStep("Create a store in a temporary directory and write a value.", OperationRef(name: "persist", subject: target, arguments: ["value": TBD])))
            steps.append(SpecStep("Discard the store and open a new instance on the same location.", OperationRef(name: "reopenStore")))
            steps.append(SpecStep("Read the value.", OperationRef(name: "read")))
            expected.append(SpecExpectation("The value survives reopening.", AssertionRef(subject: "readValue", comparator: .equals, expected: "writtenValue")))
        case "atomic-failure":
            cleanup.append(SpecStep("Delete the temporary directory.", OperationRef(name: "deleteTemporaryDirectory")))
            steps.append(SpecStep("Write version 1.", OperationRef(name: "persist", subject: target, arguments: ["value": "v1"])))
            steps.append(SpecStep("Make the next write fail (read-only location or injected failure).", OperationRef(name: "injectWriteFailure")))
            steps.append(SpecStep("Attempt to write version 2.", OperationRef(name: "persist", subject: target, arguments: ["value": "v2"])))
            steps.append(SpecStep("Read the stored value.", OperationRef(name: "read")))
            expected.append(SpecExpectation("The failed write is reported.", AssertionRef(subject: "persistV2", comparator: .throwsError, expected: TBD)))
            expected.append(SpecExpectation("Version 1 is intact.", AssertionRef(subject: "readValue", comparator: .equals, expected: "v1")))
            questions.append("How can a write failure be injected without touching real user data?")
        case "schema-version":
            steps.append(SpecStep("Load a record encoded in the previous schema version.", OperationRef(name: "loadFixture", arguments: ["fixture": TBD])))
            steps.append(invoke)
            expected.append(SpecExpectation("The old record is decoded or migrated.", AssertionRef(subject: resultSubject, comparator: .equals, expected: TBD)))
            expected.append(SpecExpectation("An unknown newer version fails closed.", AssertionRef(subject: "decodeNewerVersion", comparator: .throwsError, expected: TBD)))
            questions.append("Which prior schema versions must remain readable?")
        case "attempt-limit":
            steps.append(SpecStep("Make the dependency fail with a retryable error every time.", OperationRef(name: "arrangeAlwaysFailing", arguments: ["error": TBD])))
            steps.append(invoke)
            expected.append(SpecExpectation("Attempts stop at the configured limit.", AssertionRef(subject: "attemptCount", comparator: .equals, expected: TBD)))
            questions.append("What is the configured attempt limit?")
            tools.append("injected clock (backoff without sleeping)")
        case "auth-expired", "auth-stale", "auth-denied", "auth-replay":
            let kind = ["auth-expired": "expired", "auth-stale": "stale", "auth-denied": "denied", "auth-replay": "consumed"][b.id]!
            steps.append(SpecStep("Obtain an authorization that is \(kind).", OperationRef(name: "arrangeAuthorization", arguments: ["kind": kind])))
            if b.id == "auth-expired" { steps.append(SpecStep("Advance the injected clock past the TTL.", OperationRef(name: "advanceClock", arguments: ["seconds": TBD]))) }
            if b.id == "auth-replay" { steps.append(SpecStep("Use the authorization once successfully.", OperationRef(name: "invoke", subject: target, arguments: args))) }
            steps.append(invoke)
            if d.isThrows { expectThrow() } else {
                expected.append(SpecExpectation("The call is refused.", AssertionRef(subject: resultSubject, comparator: .equals, expected: TBD)))
                questions.append("How does \(display) report a refused authorization?")
            }
            expectNotInvoked("the protected effect (driver/executor)")
            evidence.append("refusal reason")
            failure = "A \(kind) authorization never reaches the protected effect."
        case "recovery-restart":
            steps.append(SpecStep("Persist in-flight state.", OperationRef(name: "persist", arguments: ["state": TBD])))
            steps.append(SpecStep("Simulate a restart (new instances over the same store).", OperationRef(name: "simulateRestart")))
            steps.append(SpecStep("Run recovery.", OperationRef(name: "invoke", subject: target, arguments: args)))
            expected.append(SpecExpectation("The recovered state is consistent.", AssertionRef(subject: "state", comparator: .equals, expected: TBD)))
            questions.append("Which state is correct after recovery?")
        case "recovery-unknown-outcome":
            steps.append(SpecStep("Persist an operation whose outcome is unknown (started, not finished).", OperationRef(name: "persist", arguments: ["state": "running"])))
            steps.append(SpecStep("Simulate a restart.", OperationRef(name: "simulateRestart")))
            steps.append(SpecStep("Run recovery.", OperationRef(name: "invoke", subject: target, arguments: args)))
            expectNotInvoked("the executor")
            expected.append(SpecExpectation("The operation is marked as requiring recovery.", AssertionRef(subject: "state", comparator: .equals, expected: TBD)))
            evidence.append("recorded state and events")
        case "orchestration-path", "device-mocked", "side-effect-isolated":
            steps.append(SpecStep("Compose the real collaborators with fakes at the process/device/network boundary.", OperationRef(name: "composeWithFakes", subject: target)))
            prepare("valid", "Prepare a representative request.")
            steps.append(invoke)
            expected.append(SpecExpectation("The boundary fake received exactly the expected call.", AssertionRef(subject: "fake.invocationCount", comparator: .equals, expected: "1")))
            expectValue("end-to-end path")
        case "device-live":
            steps.append(SpecStep("Run the scenario through the CLI with a human approving each step.", OperationRef(name: "runLiveScenario", subject: target, arguments: ["mode": "LIVE_HUMAN_APPROVAL", "scenario": TBD])))
            expected.append(SpecExpectation("Verification succeeds against an explicit state signal.", AssertionRef(subject: "verification.verified", comparator: .isTrue)))
            tools.append("booted simulator"); tools.append("AutonomousTestingAgent CLI")
            artifacts.append("xcresult bundle"); artifacts.append("run trace")
            evidence += ["execution ID", "approval token ID", "trace events from execution start to verification"]
            questions.append("Which fixture scenario exercises \(display)?")
        case "api-contract", "protocol-contract", "regression":
            prepare("existing", "Use inputs existing callers pass today.")
            steps.append(invoke)
            expectValue(b.id == "regression" ? "pre-change behavior" : "contract")
        case "architecture-boundary":
            steps.append(SpecStep("Scan the production source tree.", OperationRef(name: "scanSourceTree")))
            expected.append(SpecExpectation("The new dependency appears only in allow-listed files.", AssertionRef(subject: "violations", comparator: .count, expected: "0")))
        case "view-render":
            steps.append(SpecStep("Render the view in each state.", OperationRef(name: "renderView", subject: target, arguments: ["state": TBD])))
            expected.append(SpecExpectation("The rendering matches the reference.", AssertionRef(subject: "snapshot", comparator: .equals, expected: TBD)))
        default:
            steps.append(invoke)
            expectValue("input")
        }

        let liveRequired = b.liveRequired
        let why = b.id.hasPrefix("branch-") ? "added or changed branch condition"
            : b.id == "regression" ? "control flow changed" : "\(b.trait.rawValue): \(gap.traits.first { $0.trait == b.trait }?.reason ?? "detected")"
        return TestSpecification(
            id: id, title: "\(display): \(b.summary)", purpose: "Verify that \(b.summary) (\(why)).",
            category: b.category, risk: risk, targetSymbol: target, behaviorID: b.id,
            preconditions: preconditions, fixtures: fixtures, inputs: inputs, steps: steps, expectedOutcome: expected, failureExpectation: failure,
            cleanup: cleanup, requiredTools: tools, requiredMocks: mocks, requiredArtifacts: artifacts, evidenceRequirements: evidence,
            approvalRequired: liveRequired || risk == .critical, liveRequired: liveRequired,
            sourceReferences: [d.span] + (extended.map { [$0.span] } ?? []), extendsTest: extended?.id,
            status: .draft, provenance: .deterministic, openQuestions: questions)
    }

    static func displayName(_ d: Declaration) -> String {
        let leaf = d.id.leaf
        return d.container.map { "\(SymbolGraph.simpleName($0)).\(leaf)" } ?? leaf
    }

    /// Uppercase initials of the enclosing type (or symbol): `ScenarioExecutionController` -> `SEC`.
    static func idPrefix(_ d: Declaration) -> String {
        let name = d.container.map(SymbolGraph.simpleName) ?? d.name
        let initials = TraitDetector.tokens(name).compactMap(\.first).map { String($0).uppercased() }.joined()
        return String((initials.isEmpty ? "X" : initials).prefix(4))
    }

    static func categoryCode(_ c: TestCategory) -> String {
        switch c {
        case .unit: "UNT"; case .integration: "INT"; case .contract: "CON"; case .architecture: "ARC"; case .persistence: "PER"
        case .concurrency: "CNC"; case .stateMachine: "STM"; case .security: "SEC"; case .regression: "REG"; case .property: "PRP"
        case .performance: "PRF"; case .endToEnd: "E2E"; case .ui: "UIX"; case .snapshot: "SNP"; case .negative: "NEG"; case .boundary: "BND"
        }
    }
}
