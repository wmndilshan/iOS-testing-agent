import Foundation
import AgentCore

public struct Configuration: Sendable {
    public let apiKey: String
    public let model: String
    public let projectRoot: URL
    public let testUsername: String?
    public let testPassword: String?

    public init(
        apiKey: String,
        model: String,
        projectRoot: URL,
        testUsername: String? = nil,
        testPassword: String? = nil
    ) {
        self.apiKey = apiKey
        self.model = model
        self.projectRoot = projectRoot
        self.testUsername = testUsername
        self.testPassword = testPassword
    }

    public enum ConfigError: Error, LocalizedError {
        case missingAPIKey
        case envFileNotFound(String)

        public var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "API key not found. Please set LLM_API_KEY or GEMINI_API_KEY in your environment or in a .env file."
            case .envFileNotFound(let path):
                return "The .env file could not be found at: \(path)"
            }
        }
    }

    /// Checks if a key is a placeholder or fake developmental credential.
    public static func isPlaceholderKey(_ key: String) -> Bool {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ||
               normalized == "local_dev" ||
               normalized == "placeholder" ||
               normalized == "your_api_key_here" ||
               normalized == "dummy" ||
               normalized == "changeme" ||
               normalized.contains("placeholder")
    }

    /// Loads environment and `.env` values from one deterministic project root.
    public static func load(
        sourceFilePath: String = #filePath,
        environment envVars: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: URL = WorkingDirectory.url,
        explicitProjectRoot: URL? = nil
    ) throws -> Configuration {
        let rootURL = resolveProjectRoot(
            explicitProjectRoot: explicitProjectRoot,
            environment: envVars,
            currentDirectory: currentDirectory,
            sourceFilePath: sourceFilePath
        )
        var envFileValues: [String: String] = [:]
        let envFileURL = rootURL.appendingPathComponent(".env")
        if FileManager.default.fileExists(atPath: envFileURL.path) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: envFileURL.path)
            envFileValues = parseEnvFile(at: envFileURL) ?? [:]
        }

        // Environment variables take precedence over .env file
        let resolvedKey = envVars["LLM_API_KEY"]
            ?? envVars["GEMINI_API_KEY"]
            ?? envFileValues["LLM_API_KEY"]
            ?? envFileValues["GEMINI_API_KEY"]

        guard let apiKey = resolvedKey, !isPlaceholderKey(apiKey) else {
            throw ConfigError.missingAPIKey
        }

        let resolvedModel = envVars["GEMINI_MODEL"]
            ?? envVars["LLM_MODEL"]
            ?? envFileValues["GEMINI_MODEL"]
            ?? envFileValues["LLM_MODEL"]
            ?? "gemini-3.6-flash"

        let resolvedUsername = envVars["TEST_USER_USERNAME"]
            ?? envVars["SANDBOX_USERNAME"]
            ?? envFileValues["TEST_USER_USERNAME"]
            ?? envFileValues["SANDBOX_USERNAME"]

        let resolvedPassword = envVars["TEST_USER_PASSWORD"]
            ?? envVars["SANDBOX_PASSWORD"]
            ?? envFileValues["TEST_USER_PASSWORD"]
            ?? envFileValues["SANDBOX_PASSWORD"]

        return Configuration(
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            model: resolvedModel.trimmingCharacters(in: .whitespacesAndNewlines),
            projectRoot: rootURL,
            testUsername: resolvedUsername?.trimmingCharacters(in: .whitespacesAndNewlines),
            testPassword: resolvedPassword?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Resolution order: explicit argument, `ATA_PROJECT_ROOT`, the working directory when it already looks like a project (it has `TestCases/`
    /// or `.env`), nearest package root from cwd, nearest package root from this source file (a developer's build), then the cwd.
    /// The project never depends on whether a model key was found.
    public static func resolveProjectRoot(
        explicitProjectRoot: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: URL = WorkingDirectory.url,
        sourceFilePath: String = #filePath
    ) -> URL {
        if let explicitProjectRoot {
            return explicitProjectRoot.standardizedFileURL
        }
        if let configured = environment["ATA_PROJECT_ROOT"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            return URL(fileURLWithPath: configured).standardizedFileURL
        }
        let cwd = currentDirectory.standardizedFileURL
        if looksLikeProject(cwd) { return cwd }
        if let root = nearestPackageRoot(startingAt: cwd) {
            return root
        }
        let sourceDirectory = URL(fileURLWithPath: sourceFilePath).deletingLastPathComponent().standardizedFileURL
        if let root = nearestPackageRoot(startingAt: sourceDirectory) {
            return root
        }
        return cwd
    }

    private static func looksLikeProject(_ directory: URL) -> Bool {
        ["TestCases", ".env"].contains { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    private static func nearestPackageRoot(startingAt start: URL) -> URL? {
        var components = start.standardizedFileURL.pathComponents
        while !components.isEmpty {
            let candidate = URL(fileURLWithPath: NSString.path(withComponents: components), isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Package.swift").path) {
                return candidate.standardizedFileURL
            }
            guard components.count > 1 else { break }
            components.removeLast()
        }
        return nil
    }

    /// Simple .env parser supporting KEY=value, blank lines, and comments (#)
    public static func parseEnvFile(at fileURL: URL) -> [String: String]? {
        guard let data = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }
        return parseEnvContent(content)
    }

    public static func parseEnvContent(_ content: String) -> [String: String] {
        var result: [String: String] = [:]
        let lines = content.components(separatedBy: .newlines)
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Skip empty lines and comments
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            guard let equalIndex = line.firstIndex(of: "=") else {
                continue
            }
            let key = String(line[..<equalIndex]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: equalIndex)...]).trimmingCharacters(in: .whitespaces)
            
            // Strip surrounding matching quotes if present
            if (value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2) ||
               (value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2) {
                value.removeFirst()
                value.removeLast()
            }
            if !key.isEmpty {
                result[key] = value
            }
        }
        return result
    }
}
