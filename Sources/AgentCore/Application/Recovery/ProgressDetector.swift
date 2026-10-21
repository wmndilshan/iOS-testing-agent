import Foundation

// MARK: - ProgressDetector

/// Trusted state difference evaluator measuring physical UI progression between observation snapshots.
/// Security Invariant: LLM has zero authority to claim progress; only physical element hierarchy
/// deltas or property mutations count as trusted progress.
public struct ProgressDetector: Sendable {

    public init() {}

    /// Evaluates whether a meaningful state transition occurred between before and after observations.
    public func detectProgress(
        before: Observation,
        after: Observation
    ) -> (hasProgress: Bool, reason: String) {
        // 1. Snapshot identity check: if snapshot IDs are identical, no new observation was captured
        if before.snapshotID == after.snapshotID {
            return (false, "Identical snapshot ID '\(before.snapshotID)': no new UI hierarchy observed.")
        }

        // 2. Element count delta
        let countDelta = after.elements.count - before.elements.count
        if countDelta != 0 {
            return (true, "Element count changed from \(before.elements.count) to \(after.elements.count) (delta: \(countDelta > 0 ? "+\(countDelta)" : "\(countDelta)")).")
        }

        // 3. New elements appeared or existing elements disappeared
        let beforeIDs = Set(before.elements.map { $0.identifier ?? $0.label ?? $0.id })
        let afterIDs = Set(after.elements.map { $0.identifier ?? $0.label ?? $0.id })

        let added = afterIDs.subtracting(beforeIDs)
        let removed = beforeIDs.subtracting(afterIDs)

        if !added.isEmpty || !removed.isEmpty {
            return (true, "UI structure changed: +\(added.count) new elements, -\(removed.count) removed elements.")
        }

        // 4. Check modal or sheet presence delta
        let beforeFingerprint = SkillStateFingerprint.compute(from: before)
        let afterFingerprint = SkillStateFingerprint.compute(from: after)

        if beforeFingerprint.modalPresent != afterFingerprint.modalPresent {
            let change = afterFingerprint.modalPresent ? "Modal/sheet presented" : "Modal/sheet dismissed"
            return (true, "\(change).")
        }

        // 5. Check element property changes (value, enabled, hittable)
        for afterEl in after.elements {
            if let beforeEl = before.elements.first(where: { $0.id == afterEl.id || ($0.identifier != nil && $0.identifier == afterEl.identifier) }) {
                if beforeEl.value != afterEl.value {
                    return (true, "Element '\(afterEl.id)' value changed from '\(beforeEl.value ?? "")' to '\(afterEl.value ?? "")'.")
                }
                if beforeEl.isEnabled != afterEl.isEnabled {
                    return (true, "Element '\(afterEl.id)' enabled state changed to \(afterEl.isEnabled).")
                }
            }
        }

        // 6. If fingerprints match completely, no progress
        if beforeFingerprint.rawDigest == afterFingerprint.rawDigest {
            return (false, "No physical UI progress detected: state fingerprint '\(afterFingerprint.rawDigest)' unchanged.")
        }

        return (true, "State fingerprint transitioned from '\(beforeFingerprint.rawDigest)' to '\(afterFingerprint.rawDigest)'.")
    }
}
