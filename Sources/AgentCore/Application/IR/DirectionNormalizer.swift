import Foundation

/// A planner writes a scroll or swipe direction in words the tools do not take ("horizontal", "Left "). The tools take up, down, left or right, so a
/// plan that said what it meant is fixed here instead of being rejected: nothing is widened, an unknown word is left for the validator to refuse.
public enum DirectionNormalizer {
    /// "Horizontal" alone does not say which way; scrolling right reveals what is off to the right (a table's trailing columns), the usual reason to ask.
    private static let words: [String: String] = [
        "horizontal": "right", "horizontally": "right", "sideways": "right", "across": "right",
        "vertical": "down", "vertically": "down",
        "forward": "down", "backward": "up", "backwards": "up",
    ]

    public static func normalized(_ direction: String) -> String {
        let cleaned = direction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return words[cleaned] ?? cleaned
    }

    public static func normalized(_ ir: TestIR) -> TestIR {
        TestIR(testKey: ir.testKey, title: ir.title, steps: ir.steps.map(normalized))
    }

    private static func normalized(_ step: IRStep) -> IRStep {
        guard step.action == .scroll || step.action == .swipe, case .string(let direction)? = step.arguments["direction"] else { return step }
        var arguments = step.arguments
        arguments["direction"] = .string(normalized(direction))
        return IRStep(id: step.id, sourceStepNumber: step.sourceStepNumber, intent: step.intent, action: step.action, target: step.target, arguments: arguments,
                      credentialRef: step.credentialRef, wait: step.wait, branch: step.branch, verification: step.verification)
    }
}
