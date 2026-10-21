import Testing
import Foundation
@testable import AgentCore

@Suite("Drag and drop through a plan")
struct DragDestinationTests {
    private func drag(destination: AnyCodableValue?) -> IRStep {
        IRStep(id: "s1", sourceStepNumber: 1, intent: "Drag Ask to the top", action: .dragAndDrop, target: IRTarget(role: "other", identifier: "row-ask"),
               arguments: destination.map { ["destination": $0] } ?? [:])
    }

    private let destination: AnyCodableValue = .dictionary(["role": .string("other"), "identifier": .string("row-symbol"), "label": .string("Symbol")])

    @Test("The destination the planner wrote is read, and nothing else is taken for one")
    func reads() {
        let found = drag(destination: destination).dragDestination
        #expect(found?.identifier == "row-symbol" && found?.label == "Symbol" && found?.role == "other")
        #expect(drag(destination: nil).dragDestination == nil)
        #expect(drag(destination: .string("the top")).dragDestination == nil)
        #expect(drag(destination: .dictionary(["role": .string("other")])).dragDestination == nil, "a role alone names no element")
        let tap = IRStep(id: "s2", sourceStepNumber: 1, intent: "i", action: .tap, target: IRTarget(role: "button", identifier: "b"), arguments: ["destination": destination])
        #expect(tap.dragDestination == nil, "only a drag has a destination")
    }

    @Test("A drag compiles with its destination as the trusted locator; without one the step stays without it")
    func compiles() {
        guard case .compiled(let compiled) = TestIRCompiler.compile(drag(destination: destination), credentials: [:]) else { Issue.record("not compiled"); return }
        #expect(compiled.scenarioStep.destination?.identifier == "row-symbol")
        guard case .compiled(let bare) = TestIRCompiler.compile(drag(destination: nil), credentials: [:]) else { Issue.record("not compiled"); return }
        #expect(bare.scenarioStep.destination == nil)
    }

    @Test("The destination is grounded like the target: one that is not on the screen is reported, so the plan is made again")
    func grounded() {
        let vocabulary = ObservedUIVocabulary.derive(from: Observation(snapshotID: "s", bundleID: "b", appState: .runningForeground, elements: [
            UIElementSnapshot(id: "a", role: "other", label: "Ask", identifier: "row-ask"), UIElementSnapshot(id: "b", role: "other", label: "Symbol", identifier: "row-symbol")]))
        let good = ObservationGroundingService.ground(ir: TestIR(testKey: "T", title: "t", steps: [drag(destination: destination)]), vocabulary: vocabulary)
        #expect(good.issues.filter { $0.kind == "dragDestination" }.allSatisfy { $0.status == .grounded } && good.issues.contains { $0.kind == "dragDestination" })
        let gone: AnyCodableValue = .dictionary(["role": .string("other"), "identifier": .string("nowhere")])
        let bad = ObservationGroundingService.ground(ir: TestIR(testKey: "T", title: "t", steps: [drag(destination: gone)]), vocabulary: vocabulary)
        #expect(bad.issues.contains { $0.kind == "dragDestination" && $0.status != .grounded })
    }
}
