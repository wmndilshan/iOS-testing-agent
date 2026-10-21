import Foundation
import AgentCore
import AgentInfrastructure
import TestCaseSources

struct CaseStep {
    let number: Int
    let text: String
}

/// The case being run, reduced to what the runner needs: a key, a title and numbered step texts.
struct CaseDefinition {
    let key: String
    let title: String
    let steps: [CaseStep]

    init(key: String, title: String, steps: [CaseStep]) {
        self.key = key
        self.title = title
        self.steps = steps
    }

    init(_ testCase: TestCase) {
        self.init(key: testCase.key, title: testCase.title, steps: testCase.steps.map { CaseStep(number: $0.number, text: $0.text) })
    }

    private static let placeholder = try! NSRegularExpression(pattern: #"\[([A-Z][A-Z0-9_]{2,})\]"#)

    /// Test data placeholders the case leaves for the person to fill in, such as `[HELD_SYMBOL]`, in order of first use. `[CREDENTIALS]` is
    /// not one of them: the password is asked for at its own step and never stored.
    var placeholders: [String] {
        var seen = Set<String>()
        var names: [String] = []
        for step in steps {
            let range = NSRange(step.text.startIndex..., in: step.text)
            for match in Self.placeholder.matches(in: step.text, range: range) {
                guard let r = Range(match.range(at: 1), in: step.text) else { continue }
                let name = String(step.text[r])
                if name != "CREDENTIALS", seen.insert(name).inserted { names.append(name) }
            }
        }
        return names
    }

    /// The case with each `[NAME]` replaced by the value given for it. Names without a value are left as written.
    func withValues(_ values: [String: String]) -> CaseDefinition {
        CaseDefinition(key: key, title: title, steps: steps.map { step in
            var text = step.text
            for (name, value) in values where !value.isEmpty { text = text.replacingOccurrences(of: "[\(name)]", with: value) }
            return CaseStep(number: step.number, text: text)
        })
    }

    /// The case with the person's guidance applied to every step from `fromStep` on: "use Test2 instead of Test1" changes the test data and the
    /// expected result together, so the planner and the judge agree on the new value.
    func applying(_ guidance: RunGuidance, fromStep: Int = 1) -> CaseDefinition {
        guard !guidance.substitutions.isEmpty else { return self }
        return CaseDefinition(key: key, title: title, steps: steps.map { $0.number >= fromStep ? CaseStep(number: $0.number, text: guidance.apply(to: $0.text)) : $0 })
    }

    /// The username in a case is example data. This swaps in the account being tested: in every step that mentions a username,
    /// or only in `onlyStep`. A step without a `Test Data: ...` sentence is left as it is.
    func withUsername(_ username: String, onlyStep: Int? = nil) -> CaseDefinition {
        CaseDefinition(key: key, title: title, steps: steps.map { step in
            guard onlyStep == nil || step.number == onlyStep, step.text.lowercased().contains("username"),
                  let range = step.text.range(of: #"Test Data: .*?(?=\. Expected:|\.?$)"#, options: .regularExpression) else { return step }
            return CaseStep(number: step.number, text: step.text.replacingCharacters(in: range, with: "Test Data: \(username)"))
        })
    }
}

@MainActor
extension Engine {
    /// The case comes from a test case source: a local folder first, AIO when it is not there (or with --refresh).
    static func loadCase(key: String, args: [String], projectRoot: URL, handWrittenDirectory: String?) async -> TestCase {
        let cacheDirectory = projectRoot.appendingPathComponent("Scripts/AIO/generated")
        let handWritten = FileTestCaseSource(directory: projectRoot.appendingPathComponent(handWrittenDirectory ?? "TestCases"))
        do {
            let files = FileTestCaseSource(directory: cacheDirectory)
            if let own = try? await handWritten.testCase(key: key) {
                return own
            } else if !args.contains("--refresh"), let local = try? await files.testCase(key: key) {
                return local
            }
            guard let configuration = AIOConfiguration.load(projectRoot: projectRoot, caseKey: key) else {
                print("✗ \(key) is not cached and no AIO credential was found. Put AIO_API_KEY (or AIO_API_TOKEN) in .env, or set it in the environment.")
                await terminate(1)
            }
            print("Fetching \(key) from AIO (project \(configuration.project))...")
            let fetched = try await AIOTestCaseSource(configuration: configuration, cacheDirectory: cacheDirectory).testCase(key: key)
            print("✓ Fetched \(fetched.key): \(fetched.title) (\(fetched.steps.count) steps)")
            return fetched
        } catch {
            print("✗ Loading \(key) failed: \(error.localizedDescription)")
            await terminate(1)
        }
    }
}
