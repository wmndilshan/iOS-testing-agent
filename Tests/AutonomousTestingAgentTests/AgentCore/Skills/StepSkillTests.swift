import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("Step skills")
struct StepSkillTests {
    private func observation(_ identifiers: [String], secure: Set<String> = []) -> Observation {
        Observation(bundleID: "com.apple.mobilesafari", appState: .runningForeground, elements: identifiers.enumerated().map { index, id in
            UIElementSnapshot(id: "elem_\(index)", role: "button", label: id, identifier: id, isSecure: secure.contains(id))
        })
    }

    private func skill(pre: [String] = ["a", "b", "c", "d"], post: [String] = ["a", "b", "x"], text: String = "Tap Collection", actions: [StepSkillAction]? = nil) -> StepSkill {
        StepSkill(testKey: "DEMO-TC-1", stepNumber: 7, stepText: text, bundleID: "com.apple.mobilesafari",
                     actions: actions ?? [StepSkillAction(action: .tap, target: IRTarget(role: "button", identifier: "a", label: "A"), arguments: [:], intent: "Tap A")],
                     preScreen: ScreenSignature(identifiers: pre.map { "button|\($0)" }), postScreen: ScreenSignature(identifiers: post.map { "button|\($0)" }),
                     approvalSource: "explicitAutomationPolicy")
    }

    @Test("A store reads skills from the old folder, writes to the new one and forgets both")
    func testLegacyFolderFallback() async throws {
        let old = ProductFixtures.tempDir(), new = ProductFixtures.tempDir()
        let legacy = skill()
        _ = await StepSkillStore(directory: old).save(legacy)
        let store = StepSkillStore(directory: new, legacyDirectory: old)
        #expect(await store.all().map(\.id) == [legacy.id])
        #expect(await store.load(id: legacy.id) != nil)
        await store.recordSuccess(id: legacy.id)
        #expect(FileManager.default.fileExists(atPath: new.appendingPathComponent("\(legacy.id).json").path), "updates are written to the new folder")
        #expect(await store.all().count == 1)
        await store.delete(id: legacy.id)
        #expect(await store.all().isEmpty)
    }

    @Test("A screen signature ignores values, labels and secure fields, and is order independent")
    func testSignature() {
        let signature = ScreenSignature(from: observation(["b", "a", "pw"], secure: ["pw"]))
        #expect(signature.identifiers == ["button|a", "button|b"])
    }

    @Test("Similarity is 1 for the same screen, 0 for unrelated ones; containment requires nothing to be missing")
    func testSimilarityAndContainment() {
        let screen = ScreenSignature(identifiers: ["x", "y", "z"])
        #expect(screen.similarity(to: screen) == 1)
        #expect(screen.similarity(to: ScreenSignature(identifiers: ["p", "q"])) == 0)
        #expect(screen.contains(allOf: ScreenSignature(identifiers: ["x", "y"])))
        #expect(!screen.contains(allOf: ScreenSignature(identifiers: ["x", "missing"])), "an element the learned screen had is missing")
    }

    @Test("The skill ID follows the test key and the step wording, not spacing or case")
    func testSkillID() {
        #expect(StepSkill.makeID(testKey: "K", stepText: "Tap  Collection") == StepSkill.makeID(testKey: "K", stepText: "tap collection"))
        #expect(StepSkill.makeID(testKey: "K", stepText: "Tap Collection") != StepSkill.makeID(testKey: "K", stepText: "Tap Portfolio"))
        #expect(StepSkill.makeID(testKey: "K1", stepText: "Tap Collection") != StepSkill.makeID(testKey: "K2", stepText: "Tap Collection"))
    }

    @Test("A saved skill is found only for the same step, app and a similar start screen")
    func testApplicable() async {
        let store = StepSkillStore(directory: ProductFixtures.tempDir())
        #expect(await store.save(skill()))
        let same = observation(["a", "b", "c", "d"])
        #expect(await store.applicable(testKey: "DEMO-TC-1", stepText: "Tap Collection", bundleID: "com.apple.mobilesafari", observation: same) != nil)
        #expect(await store.applicable(testKey: "DEMO-TC-1", stepText: "Tap Portfolio", bundleID: "com.apple.mobilesafari", observation: same) == nil, "another step")
        #expect(await store.applicable(testKey: "DEMO-TC-1", stepText: "Tap Collection", bundleID: "com.other", observation: same) == nil, "another app")
        #expect(await store.applicable(testKey: "DEMO-TC-1", stepText: "Tap Collection", bundleID: "com.apple.mobilesafari", observation: observation(["p", "q"])) == nil, "another screen")
    }

    @Test("Three failed replays in a row quarantine a skill; a success resets the count")
    func testQuarantine() async {
        let store = StepSkillStore(directory: ProductFixtures.tempDir())
        let learned = skill()
        await store.save(learned)
        await store.recordFailure(id: learned.id)
        await store.recordFailure(id: learned.id)
        await store.recordSuccess(id: learned.id)
        #expect(await store.load(id: learned.id)?.consecutiveFailures == 0)
        for _ in 0..<StepSkill.quarantineThreshold { await store.recordFailure(id: learned.id) }
        #expect(await store.load(id: learned.id)?.quarantined == true)
        #expect(await store.applicable(testKey: "DEMO-TC-1", stepText: "Tap Collection", bundleID: "com.apple.mobilesafari", observation: observation(["a", "b", "c", "d"])) == nil)
    }

    @Test("A skill that contains something secret-shaped is refused and never written")
    func testSecretRefused() async {
        let directory = ProductFixtures.tempDir()
        let store = StepSkillStore(directory: directory)
        let leaky = skill(actions: [StepSkillAction(action: .typeText, target: IRTarget(role: "textField", identifier: "f", label: "F"),
                                                    arguments: ["text": .string("password=hunter2hunter2")], intent: "Type a key")])
        #expect(await store.save(leaky) == false)
        #expect(await store.all().isEmpty)
    }

    @Test("Saving again keeps the history of the earlier version")
    func testResaveKeepsCounters() async {
        let store = StepSkillStore(directory: ProductFixtures.tempDir())
        let learned = skill()
        await store.save(learned)
        await store.recordFailure(id: learned.id)
        await store.save(skill(post: ["a", "b", "y"]))
        let stored = await store.load(id: learned.id)
        #expect(stored?.failures == 1)
        #expect(stored?.successes == 2)
        #expect(stored?.postScreen.identifiers.contains("button|y") == true)
    }

    @Test("Launch-specific parts of an identifier (query strings, UUIDs) do not change the signature")
    func testSignatureIgnoresVolatileIdentifierParts() {
        func screen(_ identifier: String) -> ScreenSignature {
            ScreenSignature(from: Observation(bundleID: "b", appState: .runningForeground, elements: [
                UIElementSnapshot(id: "e1", role: "other", identifier: identifier)]))
        }
        #expect(screen("SafariWindow?View=Narrow&UUID=D1D86965-A832-4B10-8F08-91D10A6695CF").identifiers
                == screen("SafariWindow?View=Narrow&UUID=11111111-2222-3333-4444-555555555555").identifiers)
        #expect(screen("Window-D1D86965-A832-4B10-8F08-91D10A6695CF").identifiers == screen("Window-11111111-2222-3333-4444-555555555555").identifiers)
    }

    @Test("Short stable labels of controls tell pages apart; prices and long text do not count")
    func testSignatureUsesControlLabels() {
        func screen(_ labels: [String]) -> ScreenSignature {
            ScreenSignature(from: Observation(bundleID: "b", appState: .runningForeground, elements: labels.enumerated().map {
                UIElementSnapshot(id: "e\($0.offset)", role: "button", label: $0.element)}))
        }
        let home = screen(["Deals", "Lists", "Price 12.99"])
        let results = screen(["Most Purchased", "Spend Less", "Price 14.50"])
        #expect(home.identifiers == ["button|label:Deals", "button|label:Lists"])
        #expect(home.similarity(to: results) < ScreenSignature.minimumMatch)
        #expect(home.similarity(to: screen(["Deals", "Lists", "Price 99.99"])) == 1)
    }

    @Test("A loading indicator (reload becomes stop) does not break a match")
    func testTransientControlsIgnored() {
        let loaded = ScreenSignature(identifiers: ["button|BackButton", "button|ReloadButton", "button|MoreMenuButton"])
        let loading = ScreenSignature(identifiers: ["button|BackButton", "button|StopButton", "button|MoreMenuButton"])
        #expect(loaded.similarity(to: loading) == 1)
        #expect(loading.contains(allOf: loaded))
    }
}
