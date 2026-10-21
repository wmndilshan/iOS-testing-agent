import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("Skill library")
@MainActor
struct SkillLibraryStateTests {
    private func skill(_ text: String, step: Int) -> StepSkill {
        StepSkill(testKey: "DEMO-TC-1", stepNumber: step, stepText: text, bundleID: "com.apple.mobilesafari",
                     actions: [StepSkillAction(action: .tap, target: IRTarget(role: "button", identifier: "a", label: "A"), arguments: [:], intent: "Tap A")],
                     preScreen: ScreenSignature(identifiers: ["button|a"]), postScreen: ScreenSignature(identifiers: ["button|b"]),
                     approvalSource: "explicitAutomationPolicy")
    }

    @Test func testListsSkillsWithCountersAndQuarantine() async {
        let store = StepSkillStore(directory: ProductFixtures.tempDir())
        let a = skill("Tap A", step: 1), b = skill("Tap B", step: 2)
        await store.save(a); await store.save(b)
        for _ in 0..<StepSkill.quarantineThreshold { await store.recordFailure(id: b.id) }
        let state = SkillLibraryState(store: store)
        await state.reload()
        #expect(state.rows.map(\.stepNumber) == [1, 2])
        #expect(state.rows[0].actions == ["Tap A"] && state.rows[0].successes == 1)
        #expect(state.rows[1].quarantined && state.rows[1].failures == StepSkill.quarantineThreshold)
        #expect(state.quarantinedCount == 1)
    }

    @Test func testUnquarantineClearsTheStreak() async {
        let store = StepSkillStore(directory: ProductFixtures.tempDir())
        let a = skill("Tap A", step: 1)
        await store.save(a)
        for _ in 0..<StepSkill.quarantineThreshold { await store.recordFailure(id: a.id) }
        let state = SkillLibraryState(store: store)
        await state.unquarantine(a.id)
        #expect(state.rows.first?.quarantined == false)
        let reloaded = await store.load(id: a.id)
        #expect(reloaded?.consecutiveFailures == 0)
        await store.recordFailure(id: a.id)
        #expect(await store.load(id: a.id)?.quarantined == false)
    }

    @Test func testForgetRemovesTheSkillAndTheSelection() async {
        let store = StepSkillStore(directory: ProductFixtures.tempDir())
        let a = skill("Tap A", step: 1), b = skill("Tap B", step: 2)
        await store.save(a); await store.save(b)
        let state = SkillLibraryState(store: store)
        await state.reload()
        state.selectedID = a.id
        await state.forget(a.id)
        #expect(state.rows.map(\.id) == [b.id] && state.selectedID == nil)
        #expect(await store.load(id: a.id) == nil)
    }
}
