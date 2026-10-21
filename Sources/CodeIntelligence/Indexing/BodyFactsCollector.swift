import Foundation
import SwiftSyntax

/// Collects `BodyFacts` for one executable body (function, initializer, accessor, property initializer).
///
/// Purely syntactic: the parser output is not type-checked and operators are not folded, so receiver types are only
/// known when written down (parameters, `let x: T`, `let x = T(...)`). Everything else is left for the symbol graph.
final class BodyFactsCollector: SyntaxVisitor {
    private let converter: SourceLocationConverter
    private var facts = BodyFacts()
    private var skeleton: [String] = []
    private var conditions: [String] = []
    private var tokens: [String] = []
    private var handledCallees = Set<SyntaxIdentifier>()
    private var references: [String: Reference] = [:]
    private var concurrency = Set<String>()
    private var thrown = Set<String>()
    private var assigned = Set<String>()
    private var cases = Set<String>()
    /// Local names (parameters, bindings) and their declared type, if written.
    private var locals: [String: String?]

    static let concurrencyCalls: Set<String> = [
        "Task", "Task.detached", "withTaskGroup", "withThrowingTaskGroup", "withDiscardingTaskGroup", "withThrowingDiscardingTaskGroup",
        "withCheckedContinuation", "withCheckedThrowingContinuation", "withUnsafeContinuation", "withUnsafeThrowingContinuation",
        "withTaskCancellationHandler", "MainActor.run", "Task.sleep", "Task.checkCancellation", "Task.yield", "withLock", "addTask",
        "DispatchQueue", "DispatchSemaphore", "NSLock", "OSAllocatedUnfairLock", "Mutex", "AsyncStream", "AsyncThrowingStream",
    ]
    static let concurrencyMembers: Set<String> = ["isCancelled", "cancel", "addTask", "withLock", "lock", "unlock", "yield", "finish"]

    init(converter: SourceLocationConverter, parameters: [Parameter]) {
        self.converter = converter
        locals = Dictionary(parameters.map { ($0.name, SwiftFileIndexer.baseTypeName($0.type)) }, uniquingKeysWith: { a, _ in a })
        super.init(viewMode: .sourceAccurate)
    }

    static func collect(_ nodes: [Syntax], converter: SourceLocationConverter, parameters: [Parameter]) -> BodyFacts? {
        guard !nodes.isEmpty else { return nil }
        let c = BodyFactsCollector(converter: converter, parameters: parameters)
        for n in nodes { c.walk(n) }
        return c.finish(lines: nodes.map { $0.lineCount(converter) }.reduce(0, +))
    }

    private func finish(lines: Int) -> BodyFacts {
        facts.concurrencyConstructs = concurrency.sorted()
        facts.thrownTypes = thrown.sorted()
        facts.assignedMembers = assigned.sorted()
        facts.matchedCases = cases.sorted()
        facts.references = references.values.sorted { ($0.line, $0.name, $0.qualifier ?? "") < ($1.line, $1.name, $1.qualifier ?? "") }
        facts.branchConditions = conditions
        facts.controlFlowFingerprint = skeleton.isEmpty ? "" : Fingerprint.of(skeleton.joined(separator: "|"))
        facts.bodyFingerprint = Fingerprint.of(tokens.joined(separator: " "))
        facts.lineCount = lines
        return facts
    }

    override func visit(_ token: TokenSyntax) -> SyntaxVisitorContinueKind {
        tokens.append(token.text)
        return .visitChildren
    }

    private func line(_ node: some SyntaxProtocol) -> Int { node.startLocation(converter: converter).line }
    private func normalized(_ node: some SyntaxProtocol) -> String { SwiftFileIndexer.normalize(Syntax(node)) }
    private func branch(_ kind: String, _ node: some SyntaxProtocol) {
        conditions.append(String((kind + " " + normalized(node)).prefix(160)))
    }

    // MARK: Control flow

    override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind {
        facts.ifCount += 1
        skeleton.append("if(\(normalized(node.conditions)))")
        branch("if", node.conditions)
        return .visitChildren
    }
    override func visit(_ node: GuardStmtSyntax) -> SyntaxVisitorContinueKind {
        facts.guardCount += 1
        skeleton.append("guard(\(normalized(node.conditions)))")
        branch("guard", node.conditions)
        return .visitChildren
    }
    override func visit(_ node: SwitchExprSyntax) -> SyntaxVisitorContinueKind {
        facts.switchCount += 1
        skeleton.append("switch(\(normalized(node.subject)))")
        return .visitChildren
    }
    override func visit(_ node: SwitchCaseSyntax) -> SyntaxVisitorContinueKind {
        facts.caseCount += 1
        skeleton.append("case(\(normalized(node.label)))")
        branch("", node.label)
        if case .case(let label) = node.label {
            for item in label.caseItems {
                for m in item.pattern.tokens(viewMode: .sourceAccurate) where m.tokenKind.isIdentifier && m.previousToken(viewMode: .sourceAccurate)?.tokenKind == .period {
                    cases.insert(m.text)
                }
            }
        }
        return .visitChildren
    }
    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind { loop("for(\(normalized(node.sequence)))") }
    override func visit(_ node: WhileStmtSyntax) -> SyntaxVisitorContinueKind {
        branch("while", node.conditions)
        return loop("while(\(normalized(node.conditions)))")
    }
    override func visit(_ node: RepeatStmtSyntax) -> SyntaxVisitorContinueKind { loop("repeat(\(normalized(node.condition)))") }
    private func loop(_ s: String) -> SyntaxVisitorContinueKind {
        facts.loopCount += 1
        skeleton.append(s)
        return .visitChildren
    }
    override func visit(_ node: UnresolvedTernaryExprSyntax) -> SyntaxVisitorContinueKind {
        facts.ternaryCount += 1
        skeleton.append("?:")
        return .visitChildren
    }
    override func visit(_ node: TernaryExprSyntax) -> SyntaxVisitorContinueKind {
        facts.ternaryCount += 1
        skeleton.append("?:")
        return .visitChildren
    }
    override func visit(_ node: ReturnStmtSyntax) -> SyntaxVisitorContinueKind {
        facts.returnCount += 1
        skeleton.append("return")
        return .visitChildren
    }

    // MARK: Errors and effects

    override func visit(_ node: ThrowStmtSyntax) -> SyntaxVisitorContinueKind {
        facts.throwCount += 1
        skeleton.append("throw(\(normalized(node.expression)))")
        if let type = Self.thrownType(node.expression) { thrown.insert(type) }
        return .visitChildren
    }
    override func visit(_ node: TryExprSyntax) -> SyntaxVisitorContinueKind {
        facts.tryCount += 1
        skeleton.append("try\(node.questionOrExclamationMark?.text ?? "")")
        return .visitChildren
    }
    override func visit(_ node: CatchClauseSyntax) -> SyntaxVisitorContinueKind {
        facts.catchCount += 1
        skeleton.append("catch(\(normalized(node.catchItems)))")
        branch("catch", node.catchItems)
        return .visitChildren
    }
    override func visit(_ node: AwaitExprSyntax) -> SyntaxVisitorContinueKind {
        facts.awaitCount += 1
        skeleton.append("await")
        return .visitChildren
    }

    static func thrownType(_ expr: ExprSyntax) -> String? {
        var e = expr
        if let call = e.as(FunctionCallExprSyntax.self) { e = call.calledExpression }
        if let member = e.as(MemberAccessExprSyntax.self) {
            guard let base = member.base else { return "." }   // `throw .x`: the function's (typed) error type
            return base.trimmedDescription
        }
        if let ref = e.as(DeclReferenceExprSyntax.self), ref.baseName.text.first?.isUppercase == true { return ref.baseName.text }
        return nil
    }

    // MARK: Macros

    override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
        let name = node.macroName.text
        facts.macroUses[name, default: 0] += 1
        if ["expect", "require"].contains(name), node.arguments.first?.label?.text == "throws" { facts.throwExpectations += 1 }
        return .visitChildren
    }

    // MARK: Bindings

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.modifiers.contains(where: { $0.name.text == "async" }) { concurrency.insert("async let") }
        for b in node.bindings {
            guard let name = b.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
            var type = b.typeAnnotation.map { SwiftFileIndexer.baseTypeName($0.type.trimmedDescription) }
            if type == nil, let value = b.initializer?.value { type = Self.constructedType(value) }
            locals[name] = .some(type ?? nil)
        }
        return .visitChildren
    }
    override func visit(_ node: OptionalBindingConditionSyntax) -> SyntaxVisitorContinueKind {
        if let name = node.pattern.as(IdentifierPatternSyntax.self)?.identifier.text {
            locals[name] = .some(node.typeAnnotation.map { SwiftFileIndexer.baseTypeName($0.type.trimmedDescription) } ?? nil)
        }
        return .visitChildren
    }
    override func visit(_ node: ClosureShorthandParameterSyntax) -> SyntaxVisitorContinueKind {
        locals[node.name.text] = .some(nil)
        return .visitChildren
    }
    override func visit(_ node: ClosureParameterSyntax) -> SyntaxVisitorContinueKind {
        locals[(node.secondName ?? node.firstName).text] = .some(node.type.map { SwiftFileIndexer.baseTypeName($0.trimmedDescription) } ?? nil)
        return .visitChildren
    }

    /// `T(...)`, `try T(...)`, `await T.make(...)` -> `T`.
    static func constructedType(_ value: ExprSyntax) -> String? {
        var e = value
        while true {
            if let t = e.as(TryExprSyntax.self) { e = t.expression } else if let a = e.as(AwaitExprSyntax.self) { e = a.expression } else { break }
        }
        guard let call = e.as(FunctionCallExprSyntax.self) else { return nil }
        if let ref = call.calledExpression.as(DeclReferenceExprSyntax.self), ref.baseName.text.first?.isUppercase == true { return ref.baseName.text }
        if let m = call.calledExpression.as(MemberAccessExprSyntax.self), let base = m.base?.as(DeclReferenceExprSyntax.self),
           base.baseName.text.first?.isUppercase == true, m.declName.baseName.text == "init" { return base.baseName.text }
        return nil
    }

    // MARK: References

    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        let elements = Array(node.elements)
        for (i, e) in elements.enumerated() where i > 0 && e.is(AssignmentExprSyntax.self) {
            let target = elements[i - 1]
            if let ref = target.as(DeclReferenceExprSyntax.self), locals[ref.baseName.text] == nil { assigned.insert(ref.baseName.text) }
            if let m = target.as(MemberAccessExprSyntax.self), m.base?.trimmedDescription == "self" { assigned.insert(m.declName.baseName.text) }
        }
        return .visitChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let callee = node.calledExpression
        let calleeText = callee.trimmedDescription
        if Self.concurrencyCalls.contains(calleeText) { concurrency.insert(calleeText) }
        if let ref = callee.as(DeclReferenceExprSyntax.self) {
            handledCallees.insert(ref.id)
            record(ref.baseName.text, .call, qualifier: nil, at: node)
        } else if let m = callee.as(MemberAccessExprSyntax.self) {
            handledCallees.insert(m.id)
            handledCallees.insert(m.declName.id)   // the member name is itself a DeclReferenceExpr; it is not a bare reference
            if let base = m.base?.as(DeclReferenceExprSyntax.self) { handledCallees.insert(base.id) }
            let name = m.declName.baseName.text
            if Self.concurrencyMembers.contains(name) { concurrency.insert(name) }
            record(name, .call, qualifier: Self.qualifier(m), at: node)
            if let base = m.base?.as(DeclReferenceExprSyntax.self), base.baseName.text.first?.isUppercase == true {
                record(base.baseName.text, .type, qualifier: nil, at: node)
            }
        }
        return .visitChildren
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        handledCallees.insert(node.declName.id)
        guard !handledCallees.contains(node.id) else { return .visitChildren }
        if let base = node.base?.as(DeclReferenceExprSyntax.self) { handledCallees.insert(base.id) }
        let name = node.declName.baseName.text
        if node.base?.trimmedDescription == "Task", name == "isCancelled" { concurrency.insert("Task.isCancelled") }
        record(name, .member, qualifier: Self.qualifier(node), at: node)
        if let base = node.base?.as(DeclReferenceExprSyntax.self), base.baseName.text.first?.isUppercase == true {
            record(base.baseName.text, .type, qualifier: nil, at: node)
        }
        return .visitChildren
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        guard !handledCallees.contains(node.id) else { return .visitChildren }
        let name = node.baseName.text
        guard node.baseName.tokenKind.isIdentifier, name != "self", name != "super", locals[name] == nil else { return .visitChildren }
        record(name, name.first?.isUppercase == true ? .type : .member, qualifier: nil, at: node)
        return .visitChildren
    }

    override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
        record(node.name.text, .type, qualifier: nil, at: node)
        if Self.concurrencyCalls.contains(node.name.text) { concurrency.insert(node.name.text) }
        return .visitChildren
    }

    private static func qualifier(_ m: MemberAccessExprSyntax) -> String? {
        guard let base = m.base else { return "." }
        if let ref = base.as(DeclReferenceExprSyntax.self) { return ref.baseName.text }
        if base.is(SuperExprSyntax.self) { return "super" }
        // `a.b.c()`: the receiver is the member `b`; its type is unknown syntactically.
        if let inner = base.as(MemberAccessExprSyntax.self) { return (inner.base?.trimmedDescription == "self") ? inner.declName.baseName.text : nil }
        return nil
    }

    private func record(_ name: String, _ kind: Reference.Kind, qualifier: String?, at node: some SyntaxProtocol) {
        guard !name.isEmpty, name != "_" else { return }
        if name.hasPrefix("XCTAssert") || name == "XCTFail" {
            facts.macroUses[name, default: 0] += 1
            if name == "XCTAssertThrowsError" { facts.throwExpectations += 1 }
        }
        let receiverType = qualifier.flatMap { q in locals[q] ?? nil }
        let key = "\(kind.rawValue)|\(name)|\(qualifier ?? "")"
        guard references[key] == nil else { return }
        guard references.count < 400 else { return }
        references[key] = Reference(name: name, kind: kind, qualifier: qualifier, receiverType: receiverType, line: line(node))
    }
}

extension TokenKind {
    var isIdentifier: Bool { if case .identifier = self { return true } else { return false } }
}

extension Syntax {
    func lineCount(_ converter: SourceLocationConverter) -> Int {
        endLocation(converter: converter).line - startLocation(converter: converter).line + 1
    }
}
