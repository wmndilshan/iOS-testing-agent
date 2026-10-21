import Foundation
import AgentCore
import TestCaseSources

/// What a client can read without calling a tool: the project's test cases and the reports of past runs, each at a stable `ata://` address.
/// MCP clients show these as attachable context ("@ata://case/SAFARI-1"). Read-only by construction.
public struct GatewayResources: Sendable {
    public struct Resource: Sendable, Equatable {
        public let uri: String
        public let name: String
        public let description: String
        public let mimeType: String
    }

    public struct Contents: Sendable, Equatable {
        public let uri: String
        public let mimeType: String
        public let text: String
    }

    private let services: GatewayServices

    init(_ services: GatewayServices) { self.services = services }

    /// Most past runs listed: a client shows the list, and hundreds of old runs would bury the cases.
    static let runLimit = 30

    public func list() -> [Resource] {
        let store = FileTestCaseStore(directory: services.casesDirectory)
        var found = store.keys().map {
            Resource(uri: "ata://case/\($0)", name: $0, description: "Test case \($0) (JSON: title and steps)", mimeType: "application/json")
        }
        for entry in RunReports.all(in: services.caseRunsDirectory).prefix(Self.runLimit) {
            found.append(Resource(uri: "ata://run/\(entry.id)", name: entry.id, description: "\(entry.report.testKey) run: \(entry.report.outcome)", mimeType: "text/plain"))
            found.append(Resource(uri: "ata://run/\(entry.id)/junit", name: "\(entry.id) (JUnit)", description: "JUnit XML of this run", mimeType: "application/xml"))
        }
        return found
    }

    /// The contents behind an address, or nil when it is not one this server knows. Ids and keys are checked, so an address cannot reach another file.
    public func read(uri: String) -> Contents? {
        guard let url = URL(string: uri), url.scheme == "ata", let kind = url.host else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let name = parts.first, !name.contains(".."), !name.contains("/") else { return nil }
        switch kind {
        case "case":
            guard parts.count == 1, FileTestCaseStore.normalizedKey(name) == name,
                  let text = try? String(contentsOf: FileTestCaseStore(directory: services.casesDirectory).url(key: name), encoding: .utf8) else { return nil }
            return Contents(uri: uri, mimeType: "application/json", text: SecretRedactor.redact(text))
        case "run":
            guard let entry = RunReports.all(in: services.caseRunsDirectory).first(where: { $0.id == name }) else { return nil }
            if parts.count == 2, parts[1] == "junit" { return Contents(uri: uri, mimeType: "application/xml", text: JUnitReport.xml([(entry.id, entry.report)])) }
            guard parts.count == 1 else { return nil }
            return Contents(uri: uri, mimeType: "text/plain", text: SecretRedactor.redact(RunReports.summary(entry)))
        default:
            return nil
        }
    }
}
