import Foundation
import AgentCore

/// The app refused a value from the test data because it is already there ("Name already exists. Try a different name.").
struct DataConflict: Equatable, Sendable {
    /// The test data the screen is complaining about (`Test1`), and the sentence the app showed.
    let value: String
    let message: String
}

enum ConflictDetector {
    private static let phrase = #"\b(already exists?|already (taken|in use|used|registered)|name (is )?taken|duplicate (name|entry|value)|try a different name)\b"#

    /// The conflict on the screen, if the app is telling the test that a name or value is taken. The value is the step's own test data when it has
    /// one; otherwise the text in a filled text field.
    static func detect(_ observation: Observation?, stepText: String) -> DataConflict? {
        guard let observation else { return nil }
        let message = observation.elements.compactMap { element in
            [element.label, element.value].compactMap { $0 }.first { $0.range(of: phrase, options: [.regularExpression, .caseInsensitive]) != nil && $0.count <= 160 }
        }.first
        guard let message else { return nil }
        let field = observation.elements.first { $0.role == "textField" && !($0.value ?? "").isEmpty && $0.value != $0.placeholderValue }?.value
        guard let value = StepText.testData(in: stepText) ?? field else { return nil }
        return DataConflict(value: value, message: message.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Other values to try in place of one that is taken: the next number (Test1 → Test2), or a 2 on a name with none.
enum NameSuggester {
    static func suggest(for value: String, avoiding taken: Set<String> = [], count: Int = 3) -> [String] {
        let takenLowered = Set(taken.map { $0.lowercased() })
        var prefix = value
        var number = 1
        if let range = value.range(of: #"\d+$"#, options: .regularExpression), let n = Int(value[range]) { prefix = String(value[..<range.lowerBound]); number = n }
        var suggestions: [String] = []
        var candidate = number
        while suggestions.count < count, candidate < number + 50 {
            candidate += 1
            let name = prefix + String(candidate)
            if name.lowercased() != value.lowercased(), !takenLowered.contains(name.lowercased()) { suggestions.append(name) }
        }
        return suggestions
    }
}
