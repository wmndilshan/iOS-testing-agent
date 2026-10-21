import Foundation

/// Where a command may read host files from and write results to.
public struct DeviceValidationContext: Sendable {
    public let projectRoot: URL
    public let repository: URL?

    public init(projectRoot: URL, repository: URL?) {
        self.projectRoot = projectRoot
        self.repository = repository
    }

    /// Results (screenshots, pulled files) are written only here.
    public var outputDirectory: URL { projectRoot.appendingPathComponent(".runs/device", isDirectory: true) }
}

/// Checks a command against the catalog before anything runs: known arguments only, the right types and ranges, safe paths and URLs.
public enum DeviceCommandValidator {
    private static let secretNames: Set<String> = [".env", ".netrc", "id_rsa", "id_ed25519"]
    private static let secretExtensions: Set<String> = ["pem", "p12", "key", "pfx", "mobileprovision"]

    /// The command, normalized (a number sent as text becomes a number), or the reason it is refused.
    public static func validate(_ command: DeviceCommand, context: DeviceValidationContext) throws -> DeviceCommand {
        let spec = DeviceCommandCatalog.spec(for: command.kind)
        let known = Set(spec.params.map(\.name))
        if let unknown = command.arguments.keys.sorted().first(where: { !known.contains($0) }) {
            throw DeviceControlError.invalid("\(command.kind.rawValue) has no argument “\(unknown)”. It takes: \(known.sorted().joined(separator: ", ")).")
        }
        var normalized = command
        for param in spec.params {
            guard let value = command.arguments[param.name] else {
                if param.required { throw DeviceControlError.invalid("“\(param.name)” is required: \(param.help).") }
                continue
            }
            normalized.arguments[param.name] = try check(value, as: param, in: context)
        }
        if !spec.alternatives.isEmpty, !spec.alternatives.contains(where: { $0.allSatisfy { normalized.arguments[$0] != nil } }) {
            throw DeviceControlError.invalid("give a label, an identifier, or both x and y.")
        }
        return normalized
    }

    private static func check(_ value: DeviceValue, as param: DeviceParam, in context: DeviceValidationContext) throws -> DeviceValue {
        func fail(_ reason: String) -> DeviceControlError { .invalid("“\(param.name)” \(reason)") }
        func text() throws -> String {
            switch value {
            case .string(let s): return s
            case .number(let n): return n.rounded() == n ? String(Int(n)) : String(n)
            case .bool(let b): return b ? "true" : "false"
            }
        }
        func number() throws -> Double {
            switch value {
            case .number(let n): return n
            case .string(let s): if let n = Double(s) { return n }
            default: break
            }
            throw fail("must be a number.")
        }
        switch param.type {
        case .text(let maxLength):
            let s = try text()
            guard !s.isEmpty, s.count <= maxLength, !s.contains("\0") else { throw fail("must be 1 to \(maxLength) characters.") }
            return .string(s)
        case .integer(let range):
            let n = try number()
            guard n.rounded() == n, range.contains(Int(n)) else { throw fail("must be a whole number from \(range.lowerBound) to \(range.upperBound).") }
            return .number(n)
        case .number(let range):
            let n = try number()
            guard n.isFinite, range.contains(n) else { throw fail("must be from \(range.lowerBound) to \(range.upperBound).") }
            return .number(n)
        case .choice(let options):
            let s = try text()
            guard let match = options.first(where: { $0.caseInsensitiveCompare(s) == .orderedSame }) else { throw fail("must be one of: \(options.joined(separator: ", ")).") }
            return .string(match)
        case .bundleID:
            let s = try text()
            guard SimulatorSessionManager.isValidBundleID(s) else { throw fail("is not a valid bundle id.") }
            return .string(s)
        case .url:
            let s = try text()
            guard s.count <= 2000, let url = URL(string: s), let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { throw fail("must be a URL with a scheme, such as https://example.com.") }
            guard !["file", "javascript", "data"].contains(scheme) else { throw fail("may not use the \(scheme): scheme.") }
            return .string(s)
        case .hostFile:
            return .string(try hostFile(try text(), context: context, fail: fail))
        case .devicePath:
            let s = try text()
            let parts = s.split(separator: "/", omittingEmptySubsequences: false)
            guard !s.isEmpty, s.count <= 300, !s.hasPrefix("/"), !parts.contains(".."), !s.contains("\0"), !s.contains("\n") else { throw fail("must be a relative path inside the app's container, without “..”.") }
            return .string(s)
        case .json:
            let s = try text()
            guard s.count <= 4000, let object = try? JSONSerialization.jsonObject(with: Data(s.utf8)), object is [String: Any] else { throw fail("must be a JSON object.") }
            return .string(s)
        }
    }

    /// A file on this Mac the device may be given: it exists, lies inside the project or the repository (symbolic links resolved), and is not a secret.
    private static func hostFile(_ raw: String, context: DeviceValidationContext, fail: (String) -> DeviceControlError) throws -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        let url = (expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : context.projectRoot.appendingPathComponent(expanded)).resolvingSymlinksInPath()
        let allowed = [context.projectRoot, context.repository].compactMap { $0?.resolvingSymlinksInPath().path }
        guard allowed.contains(where: { url.path == $0 || url.path.hasPrefix($0 + "/") }) else { throw fail("must be inside the project or the repository.") }
        guard FileManager.default.fileExists(atPath: url.path) else { throw fail("does not exist: \(url.lastPathComponent).") }
        guard !secretNames.contains(url.lastPathComponent.lowercased()), !secretExtensions.contains(url.pathExtension.lowercased()) else { throw fail("looks like a secret and is never sent.") }
        return url.path
    }
}
