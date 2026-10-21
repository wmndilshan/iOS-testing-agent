import Foundation

public struct InstructionOperation: Codable, Hashable, Sendable {
    public enum Phase: String, Codable, Sendable { case setup, fixture, action, cleanup }
    public var phase: Phase
    public var name: String
    public var subject: SymbolID?
    /// Sorted by key so the instruction is byte-for-byte deterministic.
    public var arguments: [[String]]
}

public struct InstructionAssertion: Codable, Hashable, Sendable {
    public var subject: String
    public var comparator: Comparator
    public var expected: String
}

/// Framework-aware, source-free description of one test, ready for a Swift test generator.
public struct ExecutableTestInstruction: Codable, Hashable, Sendable {
    public var testID: String
    public var framework: TestFramework
    public var target: String
    public var suite: String
    /// The existing file to add to, or the suggested path for a new suite.
    public var file: String
    public var testName: String
    public var isAsync: Bool
    public var isThrows: Bool
    public var setup: [InstructionOperation]
    public var fixtures: [InstructionOperation]
    public var actions: [InstructionOperation]
    public var assertions: [InstructionAssertion]
    public var cleanup: [InstructionOperation]
    public var toolRequirements: [String]
    public var mocks: [String]
    public var timeoutSeconds: Int
    public var expectedArtifacts: [String]
    public var requiresHumanApproval: Bool
    public var liveRequired: Bool
    /// Where the generated test must run: `swift test` or a manual live CLI run.
    public var runner: String
}

public enum InstructionCompilation: Sendable {
    case ready(ExecutableTestInstruction)
    /// The spec is not executable yet; the reasons say what is missing.
    case blocked(specID: String, reasons: [String])
}

/// TestSpecification -> ExecutableTestInstruction. Refuses (never guesses) when a step has no operation, an expectation
/// has no assertion, or a placeholder is unresolved.
public enum InstructionCompiler {

    public static func compile(_ s: TestSpecification, index: ASTIndex, tests: TestIndex, framework override: TestFramework? = nil) -> InstructionCompilation {
        var reasons = TestSpecificationValidator.validate(s, index: index).filter { $0.severity == .error }.map(\.message)
        reasons += s.steps.filter { $0.operation == nil }.map { "step without operation: \($0.text)" }
        reasons += s.expectedOutcome.filter { $0.assertion == nil }.map { "expectation without assertion: \($0.text)" }
        reasons += s.unresolvedPlaceholders.map { "unresolved placeholder: \($0)" }
        guard reasons.isEmpty, let d = index[s.targetSymbol] else { return .blocked(specID: s.id, reasons: reasons.isEmpty ? ["unknown target"] : reasons) }

        // A live test never extends a unit test (and vice versa): the frameworks and runners differ.
        let existing = s.extendsTest.flatMap { tests.tests[$0] }.flatMap { ($0.framework == TestFramework.xcuitest) == s.liveRequired ? $0 : nil }
        let framework = s.liveRequired ? .xcuitest : (override ?? existing?.framework ?? tests.conventions.dominantFramework)
        let target = existing?.target ?? preferredTarget(tests, live: s.liveRequired)
        let suite = existing?.suite.map(SymbolGraph.simpleName) ?? "\(d.container.map(SymbolGraph.simpleName) ?? d.name)Tests"
        let file = existing?.span.file ?? suggestedFile(d, target: target, suite: suite)

        func ops(_ steps: [SpecStep], _ phase: InstructionOperation.Phase) -> [InstructionOperation] {
            steps.compactMap(\.operation).map { InstructionOperation(phase: phase, name: $0.name, subject: $0.subject, arguments: $0.arguments.sorted { $0.key < $1.key }.map { [$0.key, $0.value] }) }
        }
        // Only the leading arrange operations become setup; later ones stay in order among the actions (a test that
        // arranges, acts, re-arranges and acts again must keep that sequence).
        let setupNames: Set<String> = ["createTemporaryDirectory", "composeWithFakes", "arrangeState", "arrangeAuthorization", "arrangeAlwaysFailing",
                                       "arrangeCondition", "loadFixture", "injectWriteFailure", "prepareInput", "requireState"]
        let all = ops(s.steps, .action)
        let leading = all.prefix { setupNames.contains($0.name) }.count
        let setup = all.prefix(leading).map { var o = $0; o.phase = .setup; return o }
        let actions = Array(all.dropFirst(leading))
        let fixtures = s.fixtures.map { InstructionOperation(phase: .fixture, name: "use", subject: nil, arguments: [["fixture", $0]]) }
        let assertions = s.expectedOutcome.compactMap(\.assertion).map { InstructionAssertion(subject: $0.subject, comparator: $0.comparator, expected: $0.expected) }

        return .ready(ExecutableTestInstruction(
            testID: s.id, framework: framework, target: target, suite: suite, file: file, testName: testName(s),
            isAsync: d.isAsync || actions.contains { ["invokeConcurrently", "awaitAll", "startTask", "awaitTask"].contains($0.name) },
            isThrows: d.isThrows || assertions.contains { $0.comparator == .throwsError } || framework == .swiftTesting,
            setup: setup, fixtures: fixtures, actions: actions, assertions: assertions, cleanup: ops(s.cleanup, .cleanup),
            toolRequirements: s.requiredTools, mocks: s.requiredMocks, timeoutSeconds: timeout(s.category), expectedArtifacts: s.requiredArtifacts,
            requiresHumanApproval: s.approvalRequired, liveRequired: s.liveRequired,
            runner: s.liveRequired ? "manual live CLI run (--mode=LIVE_HUMAN_APPROVAL); never swift test" : "swift test --filter \(suite)"))
    }

    /// Unit tests go to the first SwiftPM test target; live tests to the UI test bundle (never to `swift test`).
    static func preferredTarget(_ tests: TestIndex, live: Bool = false) -> String {
        if live, let ui = tests.conventions.targets.first(where: { $0.contains("UITest") }) { return ui }
        return tests.conventions.targets.first { !$0.contains("UITest") } ?? tests.conventions.targets.first ?? "Tests"
    }

    /// `Sources/AgentCore/Application/Workflow/X.swift` -> `Tests/<target>/Workflow/<Suite>.swift`.
    static func suggestedFile(_ d: Declaration, target: String, suite: String) -> String {
        let parts = d.span.file.split(separator: "/").map(String.init)
        let area = parts.count >= 3 ? parts[parts.count - 2] : "Generated"
        return "Tests/\(target)/\(area)/\(suite).swift"
    }

    /// `WorkflowScheduler.recover(): an operation with unknown outcome ...` -> `testAnOperationWithUnknownOutcome...` (bounded).
    static func testName(_ s: TestSpecification) -> String {
        let summary = s.title.split(separator: ":", maxSplits: 1).last.map(String.init) ?? s.title
        let words = summary.split { !$0.isLetter && !$0.isNumber }.prefix(8).map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
        return "test" + words.joined()
    }

    static func timeout(_ c: TestCategory) -> Int {
        switch c {
        case .unit, .negative, .boundary, .regression, .contract, .property: 10
        case .architecture: 30
        case .integration, .persistence, .stateMachine, .security, .concurrency, .snapshot: 60
        case .performance: 120
        case .endToEnd, .ui: 600
        }
    }
}
