import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("22. Recovery Strategy, Budget & Progress Model Tests")
struct RecoveryAndProgressTests {

    private func makeObs(snapshotID: String, elements: [UIElementSnapshot]) -> Observation {
        Observation(snapshotID: snapshotID, bundleID: "com.apple.mobilesafari", appState: .runningForeground, elements: elements)
    }

    @Test("Progress detector detects element count delta")
    func testProgressDetectorDetectsElementCountDelta() {
        let el1 = UIElementSnapshot(id: "btn1", role: "button")
        let el2 = UIElementSnapshot(id: "btn2", role: "button")

        let obs1 = makeObs(snapshotID: "snap_1", elements: [el1])
        let obs2 = makeObs(snapshotID: "snap_2", elements: [el1, el2])

        let detector = ProgressDetector()
        let (hasProgress, reason) = detector.detectProgress(before: obs1, after: obs2)

        #expect(hasProgress == true)
        #expect(reason.contains("delta: +1"))
    }

    @Test("Progress detector detects modal presentation delta")
    func testProgressDetectorDetectsModalPresentationDelta() {
        let el1 = UIElementSnapshot(id: "login_btn", role: "button")
        let sheetEl = UIElementSnapshot(id: "modal_sheet", role: "sheet", label: "Languages", identifier: "lang-sheet")

        let obsBefore = makeObs(snapshotID: "snap_b", elements: [el1])
        let obsAfter = makeObs(snapshotID: "snap_a", elements: [sheetEl])

        let detector = ProgressDetector()
        let (hasProgress, reason) = detector.detectProgress(before: obsBefore, after: obsAfter)

        #expect(hasProgress == true)
        #expect(reason.contains("Modal/sheet presented") || reason.contains("UI structure changed"))
    }

    @Test("Progress detector rejects identical snapshots as no progress")
    func testProgressDetectorRejectsIdenticalSnapshotsAsNoProgress() {
        let el = UIElementSnapshot(id: "same_btn", role: "button", label: "Button", identifier: "btn", isEnabled: true, isHittable: true)
        let obs = makeObs(snapshotID: "snap_static", elements: [el])

        let detector = ProgressDetector()
        let (hasProgress, reason) = detector.detectProgress(before: obs, after: obs)

        #expect(hasProgress == false)
        #expect(reason.contains("Identical snapshot ID"))
    }

    @Test("Recovery budget tracker terminates loop when budget exhausted")
    func testRecoveryBudgetTrackerTerminatesOnExhaustion() {
        let policy = RecoveryPolicy(maxHealingAttempts: 2, maxRecoverySteps: 3, maxConsecutiveFailures: 3, maxNoProgressSteps: 2)
        var tracker = RecoveryBudgetTracker(policy: policy)

        #expect(tracker.isExhausted.exhausted == false)

        tracker.recordHealingAttempt()
        tracker.recordHealingAttempt()
        tracker.recordHealingAttempt() // 3 attempts exceeds limit of 2

        let result = tracker.isExhausted
        #expect(result.exhausted == true)
        #expect(result.reason?.contains("Healing budget exhausted") == true)
    }

    @Test("Recovery budget tracker terminates when consecutive no-progress limit reached")
    func testRecoveryBudgetNoProgressLimitBlocksExecution() {
        let policy = RecoveryPolicy(maxNoProgressSteps: 2)
        var tracker = RecoveryBudgetTracker(policy: policy)

        tracker.recordNoProgress()
        #expect(tracker.isExhausted.exhausted == false)

        tracker.recordNoProgress() // 2 consecutive no progress reaches limit
        let result = tracker.isExhausted
        #expect(result.exhausted == true)
        #expect(result.reason?.contains("No-progress limit reached") == true)
    }
}

// MARK: - Test Suite 23: Skill Quality, Promotion, Demotion & Decay Tests
