import Foundation

/// How an element is found for a signal: by stable identifier (preferred), else by role + label.
public struct SignalLocator: Codable, Sendable, Hashable {
    public let role: String?
    public let identifier: String?
    public let label: String?
    public init(role: String? = nil, identifier: String? = nil, label: String? = nil) { self.role = role; self.identifier = identifier; self.label = label }

    func matches(_ e: UIElementSnapshot) -> Bool {
        if let role, e.role != role { return false }
        if let identifier { return e.identifier == identifier }
        if let label { return e.label == label }
        return false
    }
}

/// A reusable, deterministic verification primitive over a fresh pre-action and a fresh post-action observation.
/// Signals compare device state; none of them consults what a driver or XCTest reported.
public enum ObservationSignal: Codable, Sendable, Hashable {
    case elementExists(SignalLocator)
    case elementAppeared(SignalLocator)
    case elementDisappeared(SignalLocator)
    /// The label of the element with this identifier changed between the two observations.
    case labelChanged(identifier: String)
    /// The label of the element with this identifier is now exactly `to` (and was not before).
    case labelBecame(identifier: String, to: String)
    case valueChanged(identifier: String)
    /// The post observation is of `bundleID`, in the foreground, chosen by the host.
    case foregroundApplication(bundleID: String)
    case accessibilitySnapshotChanged
    /// The uniquely located element was not selected before and is selected after (both states must be recorded).
    case selectedBecame(SignalLocator)
    /// The single navigation bar identified `identifier` after the action and no navigation bar did before.
    case navigationBarBecame(identifier: String)
    /// The keyboard visibility went from the opposite state to `visible`. `indeterminate` on either side never holds.
    case keyboardBecame(visible: Bool)

    /// A stable name for logs and verification reasons.
    public var name: String {
        switch self {
        case .elementExists: "elementExists"
        case .elementAppeared: "elementAppeared"
        case .elementDisappeared: "elementDisappeared"
        case .labelChanged: "labelChanged"
        case .labelBecame: "labelBecame"
        case .valueChanged: "valueChanged"
        case .foregroundApplication: "foregroundApplication"
        case .accessibilitySnapshotChanged: "accessibilitySnapshotChanged"
        case .selectedBecame: "selectedBecame"
        case .navigationBarBecame: "navigationBarBecame"
        case .keyboardBecame: "keyboardBecame"
        }
    }

    public struct Outcome: Sendable, Equatable {
        public let held: Bool
        public let reason: String
    }

    public func evaluate(pre: Observation, post: Observation) -> Outcome {
        func find(_ l: SignalLocator, _ o: Observation) -> [UIElementSnapshot] { o.elements.filter(l.matches) }
        func byID(_ id: String, _ o: Observation) -> UIElementSnapshot? {
            let hits = o.elements.filter { $0.identifier == id }
            return hits.count == 1 ? hits[0] : nil   // ambiguous identifiers never satisfy a signal
        }
        switch self {
        case .elementExists(let l):
            let n = find(l, post).count
            return Outcome(held: n == 1, reason: n == 1 ? "present" : (n == 0 ? "absent" : "ambiguous (\(n) matches)"))
        case .elementAppeared(let l):
            let before = find(l, pre).count, after = find(l, post).count
            return Outcome(held: before == 0 && after == 1, reason: "before \(before), after \(after)")
        case .elementDisappeared(let l):
            let before = find(l, pre).count, after = find(l, post).count
            return Outcome(held: before == 1 && after == 0, reason: "before \(before), after \(after)")
        case .labelChanged(let id):
            guard let a = byID(id, pre), let b = byID(id, post) else { return Outcome(held: false, reason: "'\(id)' not uniquely present in both observations") }
            return Outcome(held: a.label != b.label, reason: "'\(a.label ?? "-")' -> '\(b.label ?? "-")'")
        case .labelBecame(let id, let to):
            guard let a = byID(id, pre), let b = byID(id, post) else { return Outcome(held: false, reason: "'\(id)' not uniquely present in both observations") }
            return Outcome(held: a.label != to && b.label == to, reason: "'\(a.label ?? "-")' -> '\(b.label ?? "-")'")
        case .valueChanged(let id):
            guard let a = byID(id, pre), let b = byID(id, post) else { return Outcome(held: false, reason: "'\(id)' not uniquely present in both observations") }
            return Outcome(held: a.value != b.value, reason: "value changed: \(a.value != b.value)")
        case .foregroundApplication(let bundle):
            guard let app = post.application else { return Outcome(held: false, reason: "the observation carries no application identity") }
            return Outcome(held: app.matches(expected: bundle), reason: "\(app.bundleID) source=\(app.bundleSource) foreground=\(app.foreground)")
        case .selectedBecame(let l):
            let a = find(l, pre), b = find(l, post)
            guard a.count == 1, b.count == 1 else { return Outcome(held: false, reason: "not uniquely present in both observations (\(a.count), \(b.count))") }
            guard let was = a[0].isSelected, let now = b[0].isSelected else { return Outcome(held: false, reason: "selected state not recorded") }
            return Outcome(held: !was && now, reason: "selected \(was) -> \(now)")
        case .navigationBarBecame(let id):
            func bars(_ o: Observation) -> [UIElementSnapshot] { o.elements.filter { $0.role == "navigationBar" } }
            let before = bars(pre).filter { $0.identifier == id }.count
            let after = bars(post)
            let held = before == 0 && after.count == 1 && after[0].identifier == id
            return Outcome(held: held, reason: "before \(bars(pre).map { $0.identifier ?? "-" }), after \(after.map { $0.identifier ?? "-" })")
        case .keyboardBecame(let visible):
            guard let a = pre.application, let b = post.application else { return Outcome(held: false, reason: "an observation carries no application identity") }
            let target: ObservedKeyboard.Visibility = visible ? .visible : .hidden
            let opposite: ObservedKeyboard.Visibility = visible ? .hidden : .visible
            let (x, y) = (a.keyboardVisibility, b.keyboardVisibility)
            return Outcome(held: x == opposite && y == target, reason: "keyboard \(x.rawValue) -> \(y.rawValue)")
        case .accessibilitySnapshotChanged:
            func key(_ o: Observation) -> [String] { o.elements.map { "\($0.role)|\($0.identifier ?? "")|\($0.label ?? "")|\($0.value ?? "")" } }
            let changed = key(pre) != key(post)
            return Outcome(held: changed, reason: changed ? "hierarchy changed" : "hierarchy identical")
        }
    }
}
