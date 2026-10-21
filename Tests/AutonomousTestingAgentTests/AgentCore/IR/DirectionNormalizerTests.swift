import Testing
import Foundation
@testable import AgentCore

@Suite("Scroll and swipe directions in a plan")
struct DirectionNormalizerTests {
    private func plan(_ action: IRAction, _ direction: String?) -> TestIR {
        TestIR(testKey: "T", title: "t", steps: [IRStep(id: "s1", sourceStepNumber: 1, intent: "i", action: action, target: IRTarget(role: "scrollView", identifier: "list"),
                                                       arguments: direction.map { ["direction": .string($0)] } ?? [:])])
    }

    @Test("Words a planner uses for a direction become one the tools take; case and spaces are cleaned")
    func words() {
        #expect(DirectionNormalizer.normalized("horizontal") == "right" && DirectionNormalizer.normalized("Horizontally") == "right")
        #expect(DirectionNormalizer.normalized("vertical") == "down" && DirectionNormalizer.normalized("backwards") == "up")
        #expect(DirectionNormalizer.normalized(" Left ") == "left" && DirectionNormalizer.normalized("UP") == "up")
    }

    @Test("A scroll or swipe plan is fixed; any other step, and a direction nobody knows, is left alone for the validator")
    func plans() {
        #expect(DirectionNormalizer.normalized(plan(.scroll, "horizontal")).steps[0].arguments["direction"] == .string("right"))
        #expect(DirectionNormalizer.normalized(plan(.swipe, "Vertical")).steps[0].arguments["direction"] == .string("down"))
        #expect(DirectionNormalizer.normalized(plan(.tap, "horizontal")).steps[0].arguments["direction"] == .string("horizontal"))
        #expect(DirectionNormalizer.normalized(plan(.scroll, "diagonal")).steps[0].arguments["direction"] == .string("diagonal"))
        #expect(DirectionNormalizer.normalized(plan(.scroll, nil)).steps[0].arguments["direction"] == nil)
        let step = DirectionNormalizer.normalized(plan(.scroll, "horizontal")).steps[0]
        #expect(step.id == "s1" && step.target?.identifier == "list" && step.sourceStepNumber == 1)
    }
}
