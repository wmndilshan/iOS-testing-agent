import Foundation

/// Turns raw file changes into a `ChangeSet` by indexing the old and new text of each Swift file and comparing
/// declarations. The comparison uses facts and fingerprints, so comment/whitespace edits produce no symbol change,
/// and a moved declaration is not a change.
public enum ChangeAnalyzer {

    public static func analyze(_ raw: [RawFileChange], base: String) -> ChangeSet {
        var files: [FileChange] = []
        var symbols: [SymbolChange] = []
        var diagnostics: [String] = []
        for change in raw.sorted(by: { $0.path < $1.path }) {
            let (module, role) = RepositoryScanner.classify(change.path)
            files.append(FileChange(path: change.path, oldPath: change.oldPath, status: change.status, role: role, module: module,
                                    changedLines: change.changedLines,
                                    addedLineCount: change.changedLines.map { $0.reduce(0) { $0 + $1.count } },
                                    removedLineCount: change.removedLines.map { $0.reduce(0) { $0 + $1.count } }))
            guard change.path.hasSuffix(".swift") || (change.oldPath?.hasSuffix(".swift") ?? false) else { continue }
            if let t = change.newText ?? change.oldText, RepositoryScanner.isGenerated(path: change.path, prefix: t) {
                diagnostics.append("\(change.path): generated source, skipped")
                continue
            }
            let old = change.oldText.map { SwiftFileIndexer.index(path: change.oldPath ?? change.path, module: RepositoryScanner.classify(change.oldPath ?? change.path).module, role: role, source: $0) }
            let new = change.newText.map { SwiftFileIndexer.index(path: change.path, module: module, role: role, source: $0) }
            if (new?.file.parseErrorCount ?? 0) > 0 { diagnostics.append("\(change.path): \(new!.file.parseErrorCount) parse error(s); facts may be incomplete") }
            if change.oldText == nil, change.status != .added { diagnostics.append("\(change.path): no baseline text; every declaration treated as changed") }
            symbols += compare(old: old?.declarations, new: new?.declarations, status: change.status, file: change.path, role: role)
        }
        symbols.sort { ($0.file, $0.symbol) < ($1.file, $1.symbol) }
        let api = symbols.filter { $0.role == .production && $0.isInterface && ($0.isSignatureChange || $0.kind != .modified) }.map(\.symbol)
        return ChangeSet(base: base, files: files, symbols: symbols, apiChanges: api, diagnostics: diagnostics)
    }

    static func compare(old: [Declaration]?, new: [Declaration]?, status: FileChangeStatus, file: String, role: FileRole) -> [SymbolChange] {
        guard let new else {
            return (old ?? []).map { change($0, nil, .removed, [.declarationRemoved], file: file, role: role) }
        }
        guard let old else {
            // Added file: everything is new. Unknown baseline: everything is (conservatively) modified.
            return new.map { status == .added ? change(nil, $0, .added, [.declarationAdded], file: file, role: role) : change(nil, $0, .modified, [.body], file: file, role: role) }
        }
        var oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var unmatchedNew: [Declaration] = []
        var out: [SymbolChange] = []
        for n in new {
            if let o = oldByID.removeValue(forKey: n.id) {
                let aspects = differences(o, n)
                if !aspects.isEmpty { out.append(change(o, n, .modified, aspects, file: file, role: role)) }
            } else {
                unmatchedNew.append(n)
            }
        }
        // A declaration whose ID changed (renamed parameter label, overload types) pairs with the only unmatched old
        // declaration of the same container, name and kind.
        var unmatchedOld = Array(oldByID.values)
        for n in unmatchedNew {
            let peers = unmatchedOld.filter { $0.container == n.container && $0.name == n.name && $0.kind == n.kind }
            let newPeers = unmatchedNew.filter { $0.container == n.container && $0.name == n.name && $0.kind == n.kind }
            if peers.count == 1, newPeers.count == 1, let o = peers.first {
                unmatchedOld.removeAll { $0.id == o.id }
                var c = change(o, n, .modified, differences(o, n).union([.signature]), file: file, role: role)
                c.previousSymbol = o.id
                out.append(c)
            } else {
                out.append(change(nil, n, .added, [.declarationAdded], file: file, role: role))
            }
        }
        out += unmatchedOld.map { change($0, nil, .removed, [.declarationRemoved], file: file, role: role) }
        return out
    }

    static func differences(_ o: Declaration, _ n: Declaration) -> Set<ChangeAspect> {
        var a = Set<ChangeAspect>()
        if o.signature != n.signature { a.insert(.signature) }
        if o.parameters != n.parameters { a.insert(.parameters) }
        if o.returnType != n.returnType { a.insert(.returnType) }
        if o.access != n.access { a.insert(.access) }
        if o.isThrows != n.isThrows || o.typedThrows != n.typedThrows { a.insert(.throwing) }
        if o.isAsync != n.isAsync { a.insert(.async) }
        if o.isolationMarkers != n.isolationMarkers { a.insert(.isolation) }
        if o.genericConstraints != n.genericConstraints { a.insert(.genericConstraints) }
        if o.inheritance != n.inheritance { a.insert(.conformance) }
        if Set(o.attributes) != Set(n.attributes) { a.insert(.attributes) }
        let ob = o.body ?? BodyFacts(), nb = n.body ?? BodyFacts()
        if ob.concurrencyConstructs != nb.concurrencyConstructs { a.insert(.concurrency) }
        if (ob.throwCount, ob.tryCount, ob.catchCount) != (nb.throwCount, nb.tryCount, nb.catchCount) || ob.thrownTypes != nb.thrownTypes { a.insert(.errorHandling) }
        if ob.controlFlowFingerprint != nb.controlFlowFingerprint { a.insert(.controlFlow) }
        if ob.assignedMembers != nb.assignedMembers { a.insert(.stateMutation) }
        if ob.bodyFingerprint != nb.bodyFingerprint { a.insert(.body) }
        return a
    }

    private static func change(_ o: Declaration?, _ n: Declaration?, _ kind: SymbolChangeKind, _ aspects: Set<ChangeAspect>, file: String, role: FileRole) -> SymbolChange {
        let d = (n ?? o)!
        let access = [o?.access, n?.access].compactMap { $0 }
        var change = SymbolChange(symbol: d.id, kind: kind, aspects: aspects.sorted(), declarationKind: d.kind, file: file, role: role,
                                  oldSignature: o?.signature, newSignature: n?.signature,
                                  isInterface: access.contains { $0.isCrossFile }, isPublicAPI: access.contains { $0.isPublicAPI }, previousSymbol: nil)
        if kind == .modified, let o, let n {
            change.addedBranches = multisetDifference(n.body?.branchConditions ?? [], o.body?.branchConditions ?? [])
            change.removedBranches = multisetDifference(o.body?.branchConditions ?? [], n.body?.branchConditions ?? [])
        }
        return change
    }

    /// Elements of `a` not matched one-for-one in `b`, in `a`'s order.
    static func multisetDifference(_ a: [String], _ b: [String]) -> [String] {
        var remaining = Dictionary(b.map { ($0, 1) }, uniquingKeysWith: +)
        return a.filter { x in
            if let n = remaining[x], n > 0 { remaining[x] = n - 1; return false }
            return true
        }
    }
}
