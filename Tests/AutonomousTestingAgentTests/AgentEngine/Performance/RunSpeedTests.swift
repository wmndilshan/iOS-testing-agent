import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition
@testable import AgentEngine

@Suite("Planning tier")
struct PlanningTierTests {
    @Test("Fast first (strong only for plans that keep being rejected); strong straight away only after the step failed twice")
    func choose() {
        #expect(PlanningTier.choose(attempt: 1) == .escalating)
        #expect(PlanningTier.choose(attempt: 2) == .escalating)
        #expect(PlanningTier.choose(attempt: 3) == .strong)
        #expect(PlanningTier.choose(attempt: 0) == .escalating)
    }
}

@Suite("Quick checks")
struct QuickChecksTests {
    private func screen(_ labels: [String]) -> Observation {
        Observation(snapshotID: "s", bundleID: "b", appState: .runningForeground,
                    elements: labels.enumerated().map { UIElementSnapshot(id: "e\($0.offset)", role: "button", label: $0.element) })
    }

    @Test("Quoted labels are found, in order and once; apostrophes inside words are not quotes")
    func extraction() {
        let expected = "The user's list shows 'Mine', \"All\" and 'Not Mine'; 'All' again. It doesn't show 'x'."
        #expect(QuickChecks.labels(in: expected) == ["Mine", "All", "Not Mine"])
        #expect(QuickChecks.labels(in: "Nothing quoted here").isEmpty)
    }

    @Test("A label is found by a case-insensitive part of any label, identifier or value; secure fields are never read")
    func matching() {
        let observation = Observation(snapshotID: "s", bundleID: "b", appState: .runningForeground, elements: [
            UIElementSnapshot(id: "e1", role: "button", label: "Mine", identifier: "saved-display-filter-option-Mine"),
            UIElementSnapshot(id: "e2", role: "staticText", label: "Avg. Cost: 12.5"),
            UIElementSnapshot(id: "e3", role: "secureTextField", label: "hunter2 secret", isSecure: true),
        ])
        let result = QuickChecks.evaluate(expected: "Shows 'mine' and 'Avg. Cost' and 'UnRel' and 'hunter2 secret'", in: observation)
        #expect(result.found == ["mine", "Avg. Cost"])
        #expect(result.missing == ["UnRel", "hunter2 secret"])
        #expect(QuickChecks.evaluate(expected: "no quotes", in: screen(["x"])) == QuickChecks.Result(found: [], missing: []))
    }
}

@MainActor
@Suite("Phase clock")
struct PhaseClockTests {
    @Test("A nested phase pauses the outer one, so nothing is counted twice")
    func nested() async {
        let clock = PhaseClock()
        clock.begin(step: 1)
        await clock.measure(.judge) {
            try? await Task.sleep(nanoseconds: 120_000_000)
            await clock.measure(.settle) { try? await Task.sleep(nanoseconds: 120_000_000) }
        }
        let time = clock.finish()
        let judge = time.phases["judge"] ?? 0, settle = time.phases["settle"] ?? 0
        #expect(settle >= 0.1 && judge >= 0.1)
        #expect(judge + settle <= time.seconds + 0.05, "the parts never add up to more than the step")
        #expect(clock.timing.steps["1"] != nil)
    }

    @Test("The description names the phases and what is left")
    func describe() {
        let time = RunTiming.StepTime(seconds: 12, phases: ["plan": 4, "judge": 5, "settle": 2])
        #expect(PhaseClock.describe(time) == "12 s: plan 4, settle 2, judge 5, other 1" || PhaseClock.describe(time) == "12 s: plan 4, judge 5, settle 2, other 1")
    }

    @Test("Totals add up per phase with the unaccounted time as 'other', and old reports without timing still read")
    func totals() throws {
        var timing = RunTiming()
        timing.steps["1"] = .init(seconds: 10, phases: ["plan": 6, "judge": 3])
        timing.steps["2"] = .init(seconds: 5, phases: ["replay": 4])
        #expect(timing.totalSeconds == 15)
        #expect(timing.totals["plan"] == 6 && timing.totals["replay"] == 4 && timing.totals["other"] == 2)

        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let old = #"{"testKey":"K","title":"T","mode":"LIVE","startedAt":"2026-10-14T10:00:00Z","steps":[],"outcome":"PASSED"}"#
        #expect(try decoder.decode(CaseRunReport.self, from: Data(old.utf8)).timing == nil)
        var report = CaseRunReport(testKey: "K", title: "T", mode: "LIVE", steps: [])
        report.timing = timing
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        #expect(try decoder.decode(CaseRunReport.self, from: try encoder.encode(report)).timing == timing)
    }
}

@Suite("Untyped test data")
struct UntypedTestDataTests {
    @Test("The test data a step names is read, but not a secret or an empty one")
    func testData() {
        #expect(StepText.testData(in: "Tap the Amazon search bar and search for men watches. Test Data: men watches. Expected: Results shown") == "men watches")
        #expect(StepText.testData(in: "Enter the password. Test Data: [CREDENTIALS]. Expected: ok") == nil)
        #expect(StepText.testData(in: "Tap Login. Expected: Home") == nil)
    }

    @Test("After the first action, a step with untyped data is told to type it before submitting; not before, and not when nothing is pending")
    func note() {
        let afterTap = PlannerNotes.actionNote(stepText: "Tap the field and search. Test Data: men watches", done: ["Tap the search bar"], judgeFeedback: nil, untypedData: "men watches")
        #expect(afterTap.contains("'men watches' has not been typed yet") && afterTap.contains("typeText"))
        #expect(!PlannerNotes.actionNote(stepText: "x", done: [], judgeFeedback: nil, untypedData: "men watches").contains("not been typed"))
        #expect(!PlannerNotes.actionNote(stepText: "x", done: ["Tap"], judgeFeedback: nil).contains("not been typed"))
    }
}

@MainActor
@Suite("Judge answer cache")
struct JudgeAnswerCacheTests {
    @Test("The same picture and question share a key; a change anywhere in either does not")
    func key() {
        let image = Data((0..<20_000).map { UInt8($0 % 251) })
        var later = image
        later[19_990] ^= 1
        let key = JudgePool.cacheKey(image: image, prompt: "Expected: Home")
        #expect(key == JudgePool.cacheKey(image: image, prompt: "Expected: Home"))
        #expect(key != JudgePool.cacheKey(image: later, prompt: "Expected: Home"), "a difference far down the image still counts")
        #expect(key != JudgePool.cacheKey(image: image, prompt: "Expected: Settings"))
    }

    @Test("A stored answer is returned for its key only")
    func storeAndRead() {
        let pool = JudgePool(models: [])
        #expect(pool.cachedReply("k") == nil)
        pool.storeReply(("VERDICT: PASS", "m"), for: "k")
        #expect(pool.cachedReply("k")?.0 == "VERDICT: PASS" && pool.cachedReply("k")?.1 == "m")
        #expect(pool.cachedReply("other") == nil)
    }
}
