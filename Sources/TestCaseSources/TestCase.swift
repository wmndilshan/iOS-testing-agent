import Foundation

/// One step of a test case, as a person wrote it. The agent turns it into actions; nothing here is executable.
public struct TestCaseStep: Codable, Sendable, Equatable {
    public let number: Int
    public let action: String
    public let data: String
    public let expected: String

    public init(number: Int, action: String, data: String = "", expected: String = "") {
        self.number = number
        self.action = action
        self.data = data
        self.expected = expected
    }

    /// The step as one sentence the planner reads: action, test data, expected result.
    public var text: String {
        var parts = ["\(action)."]
        if !data.isEmpty { parts.append("Test Data: \(data).") }
        if !expected.isEmpty { parts.append("Expected: \(expected)") }
        return parts.joined(separator: " ")
    }
}

/// A test case independent of where it came from (AIO, a file, or written by hand).
public struct TestCase: Codable, Sendable, Equatable {
    public let key: String
    public let title: String
    public let source: String
    public let steps: [TestCaseStep]

    public init(key: String, title: String, source: String, steps: [TestCaseStep]) {
        self.key = key
        self.title = title
        self.source = source
        self.steps = steps
    }
}

/// Anything that can supply a test case by its key.
public protocol TestCaseSource: Sendable {
    var name: String { get }
    func testCase(key: String) async throws -> TestCase
}

public enum TestCaseSourceError: Error, LocalizedError {
    case notFound(String)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let what): "Test case not found: \(what)"
        case .unreadable(let what): "Test case could not be read: \(what)"
        }
    }
}
