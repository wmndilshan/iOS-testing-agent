import Foundation

/// The typed test taxonomy. The planner selects only the categories a change needs.
public enum TestCategory: String, Codable, Sendable, CaseIterable, Comparable {
    case unit, integration, contract, architecture, persistence, concurrency, stateMachine, security, regression
    case property, performance, endToEnd, ui, snapshot, negative, boundary

    public static func < (a: TestCategory, b: TestCategory) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }
    /// Categories that need a simulator/device or rendering infrastructure; never selected without it.
    public var needsSpecialInfrastructure: Bool { [.endToEnd, .ui, .snapshot].contains(self) }
}

/// A statically detectable behavior of a declaration that implies test obligations.
public enum BehaviorTrait: String, Codable, Sendable, CaseIterable, Comparable {
    case pureLogic, throwing, async, concurrency, stateMachine, validation, parsing, persistence, dataMigration, retryPolicy
    case authorization, security, idMapping, uiStateMapping, swiftUIView, recovery, workflowOrchestration, deviceInteraction
    case externalSideEffects, publicAPI, protocolContract, failureHandling, boundaryCrossing

    public static func < (a: BehaviorTrait, b: BehaviorTrait) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }
}

public struct TraitEvidence: Codable, Hashable, Sendable {
    public var trait: BehaviorTrait
    /// Why the detector concluded this, in terms a reviewer can check against the source.
    public var reason: String
}

/// Detects `BehaviorTrait`s from AST facts. Heuristic, deterministic and explained: every trait carries its evidence.
public enum TraitDetector {

    public static func detect(_ d: Declaration, change: SymbolChange?, index: ASTIndex) -> [TraitEvidence] {
        var out: [BehaviorTrait: String] = [:]
        func add(_ t: BehaviorTrait, _ reason: String) { if out[t] == nil { out[t] = reason } }

        let body = d.body ?? BodyFacts()
        let words = Set(tokens(d.name))
        let containerName = d.container.map(SymbolGraph.simpleName) ?? ""
        let containerWords = Set(tokens(containerName))
        let allWords = words.union(containerWords)
        let refs = body.referencedNames
        let path = d.span.file
        let imports = index.files[path]?.imports ?? []
        let container = d.container.flatMap { index[$0] }
        func any(_ set: Set<String>, _ keys: [String]) -> String? { keys.first { k in set.contains { $0.hasPrefix(k) } } }
        /// Exact referenced names; a key ending in `_` (C API families like `sqlite3_`) matches as a prefix.
        func refAny(_ keys: [String]) -> String? { keys.first { k in refs.contains { $0 == k || (k.hasSuffix("_") && $0.hasPrefix(k)) } } }

        if d.isThrows { add(.throwing, "declared `throws`" + (d.typedThrows.map { "(\($0))" } ?? "")) }
        else if body.throwCount > 0 { add(.throwing, "\(body.throwCount) throw statement(s)") }
        if d.isAsync { add(.async, "declared `async`") }

        if container?.kind == .actor || d.kind == .actor { add(.concurrency, "actor isolation") }
        else if !body.concurrencyConstructs.isEmpty { add(.concurrency, "uses " + body.concurrencyConstructs.prefix(3).joined(separator: ", ")) }
        else if let m = (d.isolationMarkers + (container?.isolationMarkers ?? [])).first(where: { $0 != "Sendable" }) { add(.concurrency, "isolation `\(m)`") }

        let stateNames = ["state", "status", "phase", "stage", "mode", "lifecycle"]
        let assignsState = body.assignedMembers.first { m in stateNames.contains { m.lowercased().hasSuffix($0) } }
        if body.switchCount > 0, !body.matchedCases.isEmpty, let s = assignsState {
            add(.stateMachine, "switches over cases and assigns `\(s)`")
        } else if let s = assignsState, any(allWords, ["transition", "advance", "complete", "begin", "finish", "cancel", "approve", "reject"]) != nil {
            add(.stateMachine, "assigns `\(s)` in a transition-named member")
        } else if any(containerWords, ["machine", "transition"]) != nil { add(.stateMachine, "state-machine type `\(containerName)`") }

        if let k = any(allWords, ["validat", "verif", "valid", "sanitiz", "admission", "admit", "check"]), body.guardCount + body.ifCount + body.throwCount > 0 {
            add(.validation, "`\(k)` naming with \(body.guardCount) guard(s)")
        }
        if let k = any(allWords, ["pars", "decod", "deserializ", "lex", "tokeniz"]) ?? refAny(["JSONDecoder", "Parser", "NSRegularExpression", "Regex", "PropertyListDecoder"]) {
            add(.parsing, "`\(k)`")
        }
        if let k = refAny(["FileManager", "sqlite3_", "UserDefaults", "removeItem", "createDirectory", "moveItem", "replaceItemAt", "fileExists"])
            ?? any(containerWords, ["store", "persist", "journal", "repositor", "database", "sqlite", "cache"]) ?? (path.contains("/Persistence/") ? "Persistence/" : nil) {
            add(.persistence, "`\(k)`")
        }
        if let k = any(allWords, ["migrat", "schema"]) ?? refAny(["schemaVersion", "migrate", "migration"]) { add(.dataMigration, "`\(k)`") }
        if let k = any(allWords, ["retry", "retries", "backoff", "attempt"]) ?? refAny(["RetryPolicy", "BackoffPolicy", "retry"]) { add(.retryPolicy, "`\(k)`") }
        if let k = any(allWords, ["authoriz", "approv", "permission", "credential", "entitle", "consume", "token"])
            ?? refAny(["DispatchAuthorizer", "ApprovalPolicy", "Authorized", "approval"]) ?? (path.contains("/Authorization/") ? "Authorization/" : nil) {
            add(.authorization, "`\(k)`")
        }
        if path.contains("/Security/") || any(allWords, ["redact", "secret", "integrity", "checksum", "sanitiz", "untrusted"]) != nil {
            add(.security, path.contains("/Security/") ? "Security layer" : "security-sensitive naming")
        }
        let mentionsID = d.parameters.contains { $0.type.hasSuffix("ID") || $0.name.hasSuffix("ID") || $0.name.hasSuffix("Id") } || (d.returnType?.hasSuffix("ID") ?? false) || d.name.contains("ID")
        if mentionsID, let k = any(words, ["map", "resolv", "lookup", "correlat", "identif", "match"]) { add(.idMapping, "`\(k)` over IDs") }
        if path.contains("/Presentation/") || containerName.hasSuffix("UIState") || containerName.hasSuffix("ViewModel") || (container?.attributes.contains("Observable") ?? false) {
            if d.kind != .struct || !(d.inheritance.contains("View")) { add(.uiStateMapping, "presentation state `\(containerName.isEmpty ? d.name : containerName)`") }
        }
        if imports.contains("SwiftUI"), d.inheritance.contains("View") || (container?.inheritance.contains("View") ?? false) { add(.swiftUIView, "SwiftUI `View`") }
        if let k = any(allWords, ["recover", "restart", "resum", "restor", "reconcil"]) { add(.recovery, "`\(k)`") }
        if let k = any(allWords, ["workflow", "schedul", "orchestrat", "job", "executor", "pipeline"])
            ?? (path.contains("/Workflow/") || path.contains("/Orchestration/") ? "Workflow/" : nil) {
            add(.workflowOrchestration, "`\(k)`")
        }
        if let k = refAny(["DeviceDriver", "SimulatorXCTestDriver", "XCUIApplication", "simctl", "UITestRunner", "SmokeTestRunning"])
            ?? any(allWords, ["simulator", "device", "driver", "xcuitest"]) ?? (path.contains("/Simulator/") || path.contains("/XCTest/") ? "Simulator/" : nil) {
            add(.deviceInteraction, "`\(k)`")
        }
        if let k = refAny(["Process", "URLSession", "NotificationCenter", "NSWorkspace"]) ?? (out[.persistence] != nil || out[.deviceInteraction] != nil ? "persistence/device I/O" : nil) {
            add(.externalSideEffects, "`\(k)`")
        }
        if body.catchCount > 0 { add(.failureHandling, "\(body.catchCount) catch clause(s)") }
        else if let k = any(words, ["fail", "error", "fallback", "abort"]) { add(.failureHandling, "`\(k)`") }

        if let change {
            if change.isPublicAPI, change.isSignatureChange { add(.publicAPI, "public signature changed") }
            if change.aspects.contains(.conformance) { add(.protocolContract, "conformance changed") }
            if change.kind != .removed, let k = refAny(["Process", "URLSession"]) ?? (imports.contains("SwiftUI") && !path.contains("/Presentation/") && path.hasPrefix("Sources/AgentCore/") ? "SwiftUI" : nil) {
                add(.boundaryCrossing, "`\(k)` in \(index.files[path]?.module ?? "module") code")
            }
        }
        if d.kind == .protocol || container?.kind == .protocol { add(.protocolContract, "protocol requirement") }

        let effectful: Set<BehaviorTrait> = [.async, .concurrency, .persistence, .externalSideEffects, .deviceInteraction, .swiftUIView, .uiStateMapping]
        if d.kind.isCallable || d.kind == .property, out.keys.allSatisfy({ !effectful.contains($0) }) { add(.pureLogic, "no effects detected") }

        return out.map { TraitEvidence(trait: $0.key, reason: $0.value) }.sorted { $0.trait < $1.trait }
    }

    /// `dispatchCurrentStep` -> ["dispatch", "current", "step"]; `URLSession` -> ["url", "session"].
    static func tokens(_ name: String) -> [String] {
        var out: [String] = []
        var current = ""
        let chars = Array(name)
        for (i, c) in chars.enumerated() {
            let boundary = c.isUppercase && !current.isEmpty
                && (chars[i - 1].isLowercase || (i + 1 < chars.count && chars[i + 1].isLowercase))
            if !c.isLetter && !c.isNumber { if !current.isEmpty { out.append(current.lowercased()); current = "" }; continue }
            if boundary { out.append(current.lowercased()); current = "" }
            current.append(c)
        }
        if !current.isEmpty { out.append(current.lowercased()) }
        return out
    }
}
