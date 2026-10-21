import Foundation

/// Where to reach AIO Tests and with which credential. The token is never printed or stored anywhere but the environment or `.env`.
public struct AIOConfiguration: Sendable {
    public static let defaultBaseURL = "https://tcms.aiojiraapps.com/aio-tcms/api/v1"

    public let baseURL: String
    public let project: String
    fileprivate let token: String

    public init(baseURL: String, project: String, token: String) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.project = project
        self.token = token
    }

    /// Reads the process environment first, then `.env` in the project root, then `Scripts/AIO/.env`. The token may be named
    /// `AIO_API_TOKEN` or `AIO_API_KEY`; the base URL defaults to the public AIO endpoint and the project to the case key's prefix.
    public static func load(projectRoot: URL, caseKey: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> AIOConfiguration? {
        var file: [String: String] = [:]
        for path in ["Scripts/AIO/.env", ".env"] {
            file.merge(parseEnvFile(projectRoot.appendingPathComponent(path))) { _, new in new }
        }
        func value(_ keys: String...) -> String? {
            for key in keys {
                if let v = environment[key], !v.isEmpty { return v }
                if let v = file[key], !v.isEmpty { return v }
            }
            return nil
        }
        guard let token = value("AIO_API_TOKEN", "AIO_API_KEY") else { return nil }
        let project = value("AIO_PROJECT") ?? caseKey.components(separatedBy: "-TC-").first ?? ""
        guard !project.isEmpty else { return nil }
        return AIOConfiguration(baseURL: value("AIO_BASE_URL") ?? defaultBaseURL, project: project, token: token)
    }

    private static func parseEnvFile(_ url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var values: [String: String] = [:]
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty { values[key] = value }
        }
        return values
    }
}

public struct AIOFetchedCase: Sendable {
    public let key: String
    public let title: String
    public let stepCount: Int
    /// The case rendered as markdown: a summary table and a `| # | Step | Test Data | Expected Result |` table.
    public let markdown: String
    public let rawJSON: Data
    public let testCase: TestCase
}

/// AIO Tests as a source of test cases, with a local copy kept so a case can be re-run offline.
public struct AIOTestCaseSource: TestCaseSource {
    public let name = "AIO"
    private let client: AIOTestCaseClient
    private let cache: URL?

    public init(configuration: AIOConfiguration, cacheDirectory: URL?, session: URLSession = .shared) {
        self.client = AIOTestCaseClient(configuration: configuration, session: session)
        self.cache = cacheDirectory
    }

    public func testCase(key: String) async throws -> TestCase {
        let fetched = try await client.fetch(caseKey: key)
        if let cache {
            try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try? fetched.markdown.write(to: cache.appendingPathComponent("\(key).md"), atomically: true, encoding: .utf8)
            try? fetched.rawJSON.write(to: cache.appendingPathComponent("\(key)_detail.json"), options: .atomic)
        }
        return fetched.testCase
    }
}

public enum AIOFetchError: Error, LocalizedError {
    case invalidKey(String)
    case http(Int, String)
    case undecodable

    public var errorDescription: String? {
        switch self {
        case .invalidKey(let key): "'\(key)' is not an AIO case key (expected something like SAFARI-1)."
        case .http(let status, let body): "AIO answered HTTP \(status): \(body)"
        case .undecodable: "AIO's answer could not be read as a test case."
        }
    }
}

/// Fetches one test case from AIO Tests (`GET {base}/project/{project}/testcase/{key}/detail`).
public struct AIOTestCaseClient: Sendable {
    private let configuration: AIOConfiguration
    private let session: URLSession

    public init(configuration: AIOConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    public func fetch(caseKey: String) async throws -> AIOFetchedCase {
        guard caseKey.range(of: #"^[A-Z]+-TC-\d+$"#, options: .regularExpression) != nil,
              let url = URL(string: "\(configuration.baseURL)/project/\(configuration.project)/testcase/\(caseKey)/detail") else {
            throw AIOFetchError.invalidKey(caseKey)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("AioAuth \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(decoding: data.prefix(200), as: UTF8.self).replacingOccurrences(of: #"(?i)(token|key|authorization)["\s:=]+[^\s",}]+"#, with: "$1=[REDACTED]", options: .regularExpression)
            throw AIOFetchError.http(status, body)
        }
        guard let detail = try? JSONDecoder().decode(Detail.self, from: data) else { throw AIOFetchError.undecodable }
        let steps = (detail.steps ?? []).enumerated().map { TestCaseStep(number: $0.offset + 1, action: $0.element.step ?? "", data: $0.element.data ?? "", expected: $0.element.expectedResult ?? "") }
        return AIOFetchedCase(key: detail.key, title: detail.title, stepCount: steps.count, markdown: detail.markdown(), rawJSON: data,
                              testCase: TestCase(key: detail.key, title: detail.title, source: "AIO", steps: steps))
    }

    // MARK: - AIO's JSON

    private struct Named: Decodable { let name: String? }
    private struct Tag: Decodable { struct Inner: Decodable { let name: String? }; let tag: Inner? }
    private struct Step: Decodable { let step: String?; let data: String?; let expectedResult: String? }

    private struct Detail: Decodable {
        let key: String
        let title: String
        let description: String?
        let precondition: String?
        let status: Named?
        let priority: Named?
        let automationStatus: Named?
        let automationKey: String?
        let scriptType: Named?
        let tags: [Tag]?
        let steps: [Step]?
        let jiraRequirementIDs: [String]?

        func markdown() -> String {
            func cell(_ value: String) -> String { value.replacingOccurrences(of: "\n", with: "<br>").replacingOccurrences(of: "|", with: "\\|") }
            var lines = ["# \(key): \(title)", "", "## Summary", "", "| Field | Value |", "|---|---|",
                         "| Key | \(key) |", "| Title | \(cell(title)) |", "| Status | \(status?.name ?? "—") |", "| Priority | \(priority?.name ?? "—") |",
                         "| Automation | \(automationStatus?.name ?? "—") |", "| Automation Key | \(automationKey ?? "—") |", "| Script Type | \(scriptType?.name ?? "—") |"]
            if let names = tags?.compactMap({ $0.tag?.name }), !names.isEmpty { lines.append("| Tags | \(cell(names.joined(separator: ", "))) |") }
            if let ids = jiraRequirementIDs, !ids.isEmpty { lines.append("| Requirements | \(cell(ids.joined(separator: ", "))) |") }
            lines.append("")
            if let text = description?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { lines += ["## Description", "", text, ""] }
            if let text = precondition?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { lines += ["## Preconditions", "", text, ""] }
            lines += ["## Steps", ""]
            if let steps, !steps.isEmpty {
                lines += ["| # | Step | Test Data | Expected Result |", "|---|---|---|---|"]
                for (index, step) in steps.enumerated() {
                    lines.append("| \(index + 1) | \(cell(step.step ?? "")) | \(cell(step.data ?? "")) | \(cell(step.expectedResult ?? "")) |")
                }
                lines.append("")
            } else {
                lines += ["_No steps defined._", ""]
            }
            lines += ["---", "", "_Generated from AIO Tests._", ""]
            return lines.joined(separator: "\n")
        }
    }
}
