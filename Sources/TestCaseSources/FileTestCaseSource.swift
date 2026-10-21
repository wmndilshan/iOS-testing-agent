import Foundation

/// Test cases kept as files in a folder: `<key>.json` (a `TestCase`) or `<key>.md` (a steps table, as the AIO source writes it).
public struct FileTestCaseSource: TestCaseSource {
    public let name = "files"
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func testCase(key: String) async throws -> TestCase {
        let json = directory.appendingPathComponent("\(key).json")
        if let data = try? Data(contentsOf: json) {
            guard let value = try? JSONDecoder().decode(TestCase.self, from: data) else { throw TestCaseSourceError.unreadable(json.lastPathComponent) }
            return value
        }
        let markdown = directory.appendingPathComponent("\(key).md")
        guard let text = try? String(contentsOf: markdown, encoding: .utf8) else { throw TestCaseSourceError.notFound("\(key) in \(directory.path)") }
        guard let value = Self.parseMarkdown(text, key: key) else { throw TestCaseSourceError.unreadable(markdown.lastPathComponent) }
        return value
    }

    /// Reads the `| # | Step | Test Data | Expected Result |` table under `## Steps`.
    static func parseMarkdown(_ text: String, key: String) -> TestCase? {
        let lines = text.components(separatedBy: "\n")
        let title = lines.first.map { $0.replacingOccurrences(of: "# \(key): ", with: "") } ?? key
        var steps: [TestCaseStep] = []
        var inSteps = false
        for line in lines {
            if line.hasPrefix("## Steps") { inSteps = true; continue }
            guard inSteps else { continue }
            if line.hasPrefix("## ") { break }
            let cells = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 6, let number = Int(cells[1]) else { continue }
            steps.append(TestCaseStep(number: number, action: cells[2], data: cells[3], expected: cells[4]))
        }
        return steps.isEmpty ? nil : TestCase(key: key, title: title, source: "files", steps: steps)
    }
}
