import Testing
import Foundation

/// Logging rules (see LOGGING_ARCHITECTURE.md): one abstraction, one redaction policy, one network owner,
/// no ad-hoc printing in library code, and logging that can never influence execution.
@Suite("Logging architecture")
struct LoggingArchitectureTests {

    private static let callRegexes = [
        try! NSRegularExpression(pattern: #"\.(?:debug|info|notice|warning|error|fault)\(\s*\.(\w+),\s*"([^"]+)""#),
        try! NSRegularExpression(pattern: #"\blog\(\s*\.\w+,\s*\.(\w+),\s*"([^"]+)""#),
    ]

    private struct Call { let file: SourceTree.File; let category: String; let event: String }

    private static let calls: [Call] = SourceTree.all.flatMap { file -> [Call] in
        let ns = file.code as NSString
        return callRegexes.flatMap { rx in
            rx.matches(in: file.code, range: NSRange(location: 0, length: ns.length)).map {
                Call(file: file, category: ns.substring(with: $0.range(at: 1)), event: ns.substring(with: $0.range(at: 2)))
            }
        }
    }

    @Test("Library code has no ad-hoc printing or platform loggers")
    func testNoAdHocLoggingInLibraryCode() {
        for file in SourceTree.core {
            for forbidden in ["print(", "debugPrint(", "NSLog(", "os_log", "Logger(", "dump(", "fputs(", "FileHandle.standardOutput", "FileHandle.standardError"] {
                let allowed = forbidden == "FileHandle.standardError" && file.name == "LogDestination.swift"
                let pattern = "(?<![A-Za-z0-9_])" + NSRegularExpression.escapedPattern(for: forbidden)
                let real = (try? NSRegularExpression(pattern: pattern))
                    .map { $0.numberOfMatches(in: file.symbols, range: NSRange(location: 0, length: (file.symbols as NSString).length)) } ?? 0
                #expect(allowed || real == 0, "\(file.path) uses \(forbidden): use AppLogger")
            }
        }
    }

    @Test("Printing exists only in the CLI (terminal output) and the app's snapshot markers")
    func testPrintOnlyInEntryPoints() {
        let rx = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])print\("#)
        for file in SourceTree.all where !(file.module.map(SourceTree.coreModules.contains) ?? false) {
            let n = rx.numberOfMatches(in: file.symbols, range: NSRange(location: 0, length: (file.symbols as NSString).length))
            #expect(n == 0 || file.isCLI || file.path.hasPrefix("Sources/GUI/"), "\(file.path)")
        }
    }

    @Test("Every logged event name is lowercase dotted and every category is a declared LogCategory")
    func testEventNamesAndCategoriesAreControlled() {
        #expect(Self.calls.count >= 20, "the scan must see the instrumentation")
        let categories = Set(["application", "lifecycle", "configuration", "llm", "llmNetwork", "proposal", "validation", "approval", "authorization",
                              "execution", "tool", "xctest", "simulator", "observation", "verification", "recovery", "skills", "persistence",
                              "inspector", "integration", "security", "performance"])
        for call in Self.calls {
            #expect(LogEventName.isValid(call.event), "\(call.file.path): '\(call.event)'")
            #expect(categories.contains(call.category), "\(call.file.path): unknown category .\(call.category)")
        }
    }

    @Test("Network logging has exactly one owner: the LLM gateway")
    func testNetworkCategoryIsOwnedByTheGateway() {
        let owners = Set(Self.calls.filter { $0.category == "llmNetwork" }.map(\.file.name))
        #expect(owners == ["LLMGateway.swift"], "\(owners)")
        for call in Self.calls where call.event.hasPrefix("llm.network.") { #expect(call.file.name == "LLMGateway.swift") }
    }

    @Test("Logger calls never pass credential-looking values")
    func testLoggerCallsDoNotReferenceSecrets() {
        for file in SourceTree.all {
            for line in file.code.split(separator: "\n") where line.contains("logger.") || line.contains("log(.") {
                for secret in ["apiKey", "password", "Password", "Authorization", "credentials", "humanInputUsername"] {
                    #expect(!line.contains(secret), "\(file.path) logs '\(secret)': \(line.trimmingCharacters(in: .whitespaces))")
                }
                #expect(line.unicodeScalars.allSatisfy { $0.value < 0x80 }, "\(file.path): log calls are plain ASCII, no emoji")
            }
        }
    }

    @Test("The logging abstraction is pure and observational")
    func testLoggerCannotAffectExecution() {
        let proto = SourceTree.core.first { $0.name == "AppLogger.swift" }!.code
        #expect(proto.contains("func log(_ event: LogEvent)\n"), "log must return Void")
        #expect(!proto.contains("throws") && !proto.contains("async"), "logging cannot throw or suspend")
        for file in SourceTree.core where file.layer == "Shared" && file.inLayer("Logging") {
            for forbidden in ["URLSession", "FileManager", "FileHandle", "Process(", "import SwiftUI", "ProcessInfo"] {
                #expect(!file.code.contains(forbidden), "\(file.path) must stay pure: \(forbidden)")
            }
        }
        // The controller only emits: no decision reads the logger.
        let controller = SourceTree.core.filter(\.isController)
        let uses = controller.flatMap { $0.code.split(separator: "\n").filter { $0.contains("logger") } }.map { $0.trimmingCharacters(in: .whitespaces) }
        for line in uses {
            #expect(line.hasPrefix("public var logger") || line.hasPrefix("guard logger.isEnabled") || line.hasPrefix("logger.log(") || line.hasPrefix("///"), "\(line)")
        }
    }

    @Test("Concrete destinations and redaction live where the layers say")
    func testDestinationsAndRedactionPlacement() {
        for name in ["ConsoleLogDestination", "FileLogDestination", "DestinationLogger", "LoggerFactory"] {
            let declaring = SourceTree.core.filter { $0.code.contains("struct \(name)") || $0.code.contains("class \(name)") || $0.code.contains("enum \(name)") }
            #expect(declaring.allSatisfy { $0.layer == "Infrastructure" && $0.inLayer("Logging") }, "\(name)")
        }
        #expect(SourceTree.core.first { $0.name == "LogRedactor.swift" }?.layer == "Security")
        // Destinations are only ever fed through DestinationLogger (which redacts first).
        for file in SourceTree.core where file.layer != "Infrastructure" || !file.inLayer("Logging") {
            #expect(!file.code.contains(".write(event)") && !file.symbols.contains("LogDestination"), "\(file.path)")
        }
    }
}

/// Mirrors `LogEvent.isValidName` so this architecture test does not depend on the module under scan.
enum LogEventName {
    static func isValid(_ name: String) -> Bool {
        name.range(of: #"^[a-z0-9_]+(\.[a-z0-9_]+)+$"#, options: .regularExpression) != nil
    }
}
