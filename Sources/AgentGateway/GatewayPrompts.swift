import Foundation

/// Ready-made instructions a client offers as slash commands ("/ata:triage_failure"). Each one only tells the agent how to use the tools for a
/// common job; it holds no logic and runs nothing.
public enum GatewayPrompts {
    public struct Argument: Sendable, Equatable {
        public let name: String
        public let description: String
        public let required: Bool
    }

    public struct Prompt: Sendable, Equatable {
        public let name: String
        public let description: String
        public let arguments: [Argument]
        let text: @Sendable ([String: String]) -> String
        public static func == (lhs: Prompt, rhs: Prompt) -> Bool { lhs.name == rhs.name }
    }

    public static let all: [Prompt] = [
        Prompt(name: "write_case", description: "Write a test case for a feature by looking at the running app.",
               arguments: [Argument(name: "feature", description: "What the case should check, in plain words", required: true)]) { args in
            """
            Write a test case for: \(args["feature"] ?? "the feature the person describes").
            1. list_cases, so you do not duplicate an existing case.
            2. Look at the app with device_observe (read_screen), and walk to the feature with device_input; do not guess labels.
            3. Write 3 to 10 steps with write_case. Each step names one action and an expected result that quotes labels exactly as they appear on screen. Never write a password: use [CREDENTIALS].
            4. Run it with run_case and fix any step that fails because of its wording, not because of the app.
            """
        },
        Prompt(name: "triage_failure", description: "Find out why a run failed and say whether the app or the case is at fault.",
               arguments: [Argument(name: "run_id", description: "A run id from list_runs; default the latest failed run", required: false)]) { args in
            """
            Work out why \(args["run_id"].map { "run \($0)" } ?? "the latest failed run") failed.
            1. list_runs, then get_report for the run. Find the first failed step and read its detail.
            2. Read the case with read_case and compare the failed step with what the report says was on screen.
            3. Decide: the app is wrong (a real bug: quote the label or behaviour), the case is wrong (a label changed or the step is vague: propose the corrected step), or the run was disturbed (a system dialog, a timeout, a device problem).
            4. Report the verdict in three lines: step, cause, fix. Do not change the case unless the person asks.
            """
        },
        Prompt(name: "plan_for_diff", description: "Choose and run the tests a code change needs.",
               arguments: [Argument(name: "base", description: "Git ref to compare against, default the repository's default branch", required: false)]) { args in
            """
            Decide which tests a code change needs\(args["base"].map { " compared with \($0)" } ?? "").
            1. plan_tests\(args["base"].map { " with base=\($0)" } ?? ""): read its risk, impacted symbols and gaps.
            2. list_cases and read_case for the cases that touch the changed screens.
            3. For a gap with no case, draft one with generate_cases or write_case. For the cases that apply, run them with run_case, most risky first.
            4. Summarise: what changed, which cases ran and their outcomes, and what is still not covered.
            """
        },
    ]

    public static func prompt(named name: String) -> Prompt? { all.first { $0.name == name } }

    /// The prompt's message, or nil when a required argument is missing.
    public static func render(_ prompt: Prompt, arguments: [String: String]) -> String? {
        for argument in prompt.arguments where argument.required && (arguments[argument.name] ?? "").isEmpty { return nil }
        return prompt.text(arguments)
    }
}
