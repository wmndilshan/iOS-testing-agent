import Foundation
import CodeIntelligence

/// Everything the analyst needs from the repository, built once per conversation and kept in memory: the CodeIntelligence AST index
/// (declarations only: no body facts, no tests, no generated `Derived` code, which is what keeps a 4000-file app fast) and the text of the
/// files worth searching. `prewarm` builds it in the background while the first model call runs, so
/// the first tool call does not pay for indexing. Nothing here writes to the repository; the index cache lives in this project.
final class RepoKnowledge: @unchecked Sendable {
    struct TextFile: Sendable {
        let path: String
        let lines: [String]
        /// The whole file lowercased: one substring test decides whether any line can match, so most files are never scanned line by line.
        let lowered: String

        init(path: String, lines: [String]) {
            self.path = path
            self.lines = lines
            lowered = lines.joined(separator: "\n").lowercased()
        }
    }

    let sandbox: RepoSandbox
    /// The full test-planning index cache (`plan_tests`) and the small declarations-only cache the browsing tools use.
    let cacheURL: URL
    let lightCacheURL: URL
    private let lock = NSLock()
    private var builtIndex: (index: ASTIndex, statistics: RepositoryScanner.Statistics)?
    private var builtFiles: [TextFile]?

    /// Source, project settings and docs. Not json or txt: an app's asset catalogs hold tens of thousands of `Contents.json` files.
    private static let textExtensions: Set<String> = ["swift", "md", "plist", "yml", "yaml", "pbxproj", "xcconfig", "strings", "storyboard", "xib", "m", "h"]
    private static let skippedFolders: Set<String> = ["DerivedData", "node_modules", "Pods", "Carthage", "evidence", "Fixtures", "Derived"]
    private static let skippedFolderExtensions: Set<String> = ["xcassets", "xcarchive", "xcresult", "framework", "bundle", "dSYM", "app", "lproj", "imageset", "appiconset", "xcdatamodeld", "playground"]

    init(sandbox: RepoSandbox, projectRoot: URL) {
        self.sandbox = sandbox
        let name = sandbox.root.lastPathComponent.filter { $0.isLetter || $0.isNumber }
        let hash = sandbox.root.path.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
        cacheURL = projectRoot.appendingPathComponent(".build/agent-code-intelligence/\(name)-\(hash).json")
        lightCacheURL = projectRoot.appendingPathComponent(".build/agent-code-intelligence/\(name)-\(hash)-light.json")
    }

    func prewarm() {
        DispatchQueue.global(qos: .utility).async { [self] in _ = index() }
        DispatchQueue.global(qos: .utility).async { [self] in _ = textFiles() }
    }

    /// Tests and generated code are not what a new test case is written from, and they are about half of a large app's files.
    static func isNoise(_ path: String) -> Bool {
        path.split(separator: "/").dropLast().contains { $0 == "Derived" || $0.hasSuffix("Tests") || $0 == "TestCases" || $0 == "Mocks" }
    }

    func index() -> (index: ASTIndex, statistics: RepositoryScanner.Statistics) {
        lock.lock(); defer { lock.unlock() }
        if let builtIndex { return builtIndex }
        let result = RepositoryScanner(root: sandbox.root).buildIndex(cacheURL: lightCacheURL, bodies: false, include: { !RepoKnowledge.isNoise($0) })
        builtIndex = result
        return result
    }

    /// Readable text files (source, project, plist, docs) with their lines, loaded once. Hidden folders, build output and big files are left out.
    func textFiles() -> [TextFile] {
        lock.lock(); defer { lock.unlock() }
        if let builtFiles { return builtFiles }
        var files: [TextFile] = []
        if let walker = FileManager.default.enumerator(at: sandbox.root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]) {
            for case let url as URL in walker {
                let name = url.lastPathComponent
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                let isDirectory = values?.isDirectory == true
                if name.hasPrefix(".") || Self.skippedFolders.contains(name) || (isDirectory && Self.skippedFolderExtensions.contains(url.pathExtension)) {
                    if isDirectory { walker.skipDescendants() }
                    continue
                }
                let ext = url.pathExtension.lowercased()
                guard !isDirectory, Self.textExtensions.contains(ext) else { continue }
                // A project file is megabytes: only its bundle identifier lines matter.
                let isProject = ext == "pbxproj"
                guard (values?.fileSize ?? 0) <= (isProject ? 30_000_000 : 200_000) else { continue }
                let relative = sandbox.relativePath(url)
                guard (try? sandbox.resolve(relative)) != nil, let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let lines = text.components(separatedBy: "\n")
                files.append(TextFile(path: relative, lines: isProject ? lines.filter { $0.contains("PRODUCT_BUNDLE_IDENTIFIER") } : lines))
            }
        }
        files.sort { $0.path < $1.path }
        builtFiles = files
        return files
    }

    /// `path:line: text` for lines containing `query` (case-insensitive): at most `perFile` per file and `limit` in all, so one noisy file cannot fill the answer.
    func search(_ query: String, under folder: String = ".", limit: Int = 25, perFile: Int = 3) -> [String] {
        let needle = query.lowercased()
        let prefix = folder == "." || folder.isEmpty ? "" : folder.hasSuffix("/") ? folder : folder + "/"
        var hits: [String] = []
        for file in textFiles() where (prefix.isEmpty || file.path.hasPrefix(prefix)) && file.lowered.contains(needle) {
            var inFile = 0
            for (offset, line) in file.lines.enumerated() where line.range(of: needle, options: [.caseInsensitive, .literal]) != nil {
                hits.append("\(file.path):\(offset + 1): \(line.trimmingCharacters(in: .whitespaces).prefix(110))")
                inFile += 1
                if inFile >= perFile || hits.count >= limit { break }
            }
            if hits.count >= limit { break }
        }
        return hits
    }
}

/// Reads the AST index like a person reads a codebase's map: what screens exist, what a file declares, who uses a type, which words are on screen.
enum RepoInsights {
    private static let screenProtocols = ["View", "UIViewController", "UIViewControllerRepresentable", "NSViewController", "App"]
    private static let stateProtocols = ["ObservableObject", "Observable"]
    private static let navigationName = try! NSRegularExpression(pattern: "(Section|Tab|Route|Screen|Page|Destination|Step)s?$")

    static func overview(_ knowledge: RepoKnowledge) -> String {
        let (index, stats) = knowledge.index()
        func place(_ d: Declaration) -> String { "\(d.name) \(d.span.file):\(d.span.line)" }
        // The index already leaves out tests and generated code, so every indexed declaration counts. (Roles are not used: the scanner
        // assigns them by the SwiftPM layout, and an Xcode or Tuist app keeps its code under Targets/.)
        func production(_ ds: [Declaration]) -> [Declaration] { ds }

        var out = ["Indexed \(stats.files) Swift files, \(stats.declarations) declarations."]
        let bundles = bundleIdentifiers(knowledge)
        out.append("Bundle identifiers: " + (bundles.isEmpty ? "none found" : bundles.joined(separator: ", ")))

        var folders: [String: Int] = [:]
        for file in index.files.values {
            let parts = file.path.split(separator: "/")
            let depth = ["Targets", "Sources", "Modules", "Packages", "Libraries"].contains(String(parts.first ?? "")) ? 3 : 2
            folders[parts.dropLast().prefix(depth).joined(separator: "/"), default: 0] += 1
        }
        out.append("Production folders (Swift files): " + folders.sorted { $0.key < $1.key }.prefix(24).map { "\($0.key) \($0.value)" }.joined(separator: ", "))

        let entry = production(index.declarations.values.filter { $0.attributes.contains("main") }.sorted { $0.id < $1.id })
        if !entry.isEmpty { out.append("Entry points (@main): " + entry.prefix(5).map(place).joined(separator: "; ")) }

        let navigation = production(index.declarations.values.filter { $0.kind == .enum && navigationName.firstMatch(in: $0.name, range: NSRange($0.name.startIndex..., in: $0.name)) != nil }.sorted { $0.id < $1.id })
        for type in navigation.prefix(6) {
            let cases = index.members(of: type.id).filter { $0.kind == .enumCase }.map(\.name)
            if !cases.isEmpty { out.append("Navigation enum \(place(type)): " + cases.prefix(14).joined(separator: ", ")) }
        }

        var screens: [Declaration] = []
        for proto in screenProtocols { screens += production(index.conformances(to: proto).filter { $0.kind.isType }) }
        let uniqueScreens = Dictionary(grouping: screens, by: \.id).compactMap { $0.value.first }.sorted { $0.id < $1.id }
        out.append("Screens/views (\(uniqueScreens.count)): " + uniqueScreens.prefix(40).map(place).joined(separator: "; "))

        var models: [Declaration] = []
        for proto in stateProtocols { models += production(index.conformances(to: proto).filter { $0.kind.isType }) }
        models += production(index.declarations.values.filter { $0.attributes.contains("Observable") && $0.kind.isType })
        let uniqueModels = Dictionary(grouping: models, by: \.id).compactMap { $0.value.first }.sorted { $0.id < $1.id }
        if !uniqueModels.isEmpty { out.append("State models (\(uniqueModels.count)): " + uniqueModels.prefix(25).map(place).joined(separator: "; ")) }

        let identifiers = knowledge.search("accessibilityIdentifier", limit: 5000, perFile: 5000).count
        out.append("accessibilityIdentifier uses: \(identifiers). Next: ui_strings(path) for the words on a screen, file_outline(path) for a file's declarations, describe_symbol(name) for a type.")
        return out.joined(separator: "\n")
    }

    /// Bundle ids written as literals in Xcode projects, plists and xcconfig files.
    static func bundleIdentifiers(_ knowledge: RepoKnowledge) -> [String] {
        var found: [String] = []
        let pattern = try! NSRegularExpression(pattern: #"(?:PRODUCT_BUNDLE_IDENTIFIER\s*=\s*"?|<string>)([A-Za-z][A-Za-z0-9-]*(?:\.[A-Za-z0-9-]+)+)"?"#)
        for file in knowledge.textFiles() where ["pbxproj", "xcconfig", "plist"].contains((file.path as NSString).pathExtension) {
            for line in file.lines where line.contains("PRODUCT_BUNDLE_IDENTIFIER") || (file.path.hasSuffix(".plist") && line.contains("<string>com.")) {
                if let match = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), let range = Range(match.range(at: 1), in: line) {
                    let id = String(line[range])
                    if !found.contains(id), !id.hasSuffix("Tests"), !id.hasSuffix("UITests") { found.append(id) }
                }
            }
        }
        return Array(found.prefix(8))
    }

    static func outline(_ knowledge: RepoKnowledge, path: String) -> String {
        let (index, _) = knowledge.index()
        let declarations = index.symbols(inFile: path).filter { $0.access >= .internal || $0.kind.isType }.sorted { $0.span.line < $1.span.line }
        guard !declarations.isEmpty else { return "\(path) has no indexed declarations (not a Swift file in the index). Use read_file." }
        var depth: [SymbolID: Int] = [:]
        var lines: [String] = []
        for d in declarations.prefix(120) {
            let level = d.container.flatMap { depth[$0] }.map { $0 + 1 } ?? 0
            depth[d.id] = level
            lines.append("\(String(repeating: "  ", count: level))\(d.span.line): \(d.signature.prefix(110))")
        }
        return "\(path) — \(declarations.count) declarations\n" + lines.joined(separator: "\n") + (declarations.count > 120 ? "\n…" : "")
    }

    static func describe(_ knowledge: RepoKnowledge, name: String) -> String {
        let (index, _) = knowledge.index()
        let exact = index.declarations.values.filter { $0.name == name }.sorted { ($0.kind.isType ? 0 : 1, $0.id) < ($1.kind.isType ? 0 : 1, $1.id) }
        guard !exact.isEmpty else {
            let near = index.declarations.values.filter { $0.name.range(of: name, options: .caseInsensitive) != nil && $0.kind.isType }.sorted { $0.id < $1.id }.prefix(8).map(\.name)
            return "No declaration named \(name)." + (near.isEmpty ? "" : " Similar types: " + near.joined(separator: ", "))
        }
        var out: [String] = []
        for d in exact.prefix(3) {
            out.append("\(d.kind.rawValue) \(d.signature.prefix(160))  [\(d.span.file):\(d.span.line)-\(d.span.endLine)]")
            if !d.inheritance.isEmpty { out.append("  conforms to: " + d.inheritance.joined(separator: ", ")) }
            let members = index.members(of: d.id).filter { $0.access >= .internal }.sorted { $0.span.line < $1.span.line }
            if !members.isEmpty { out.append("  members: " + members.prefix(30).map { "\($0.name)@\($0.span.line)" }.joined(separator: ", ")) }
        }
        // Users of the name, by word match over the files kept in memory (no symbol graph: it needs the heavy full index).
        let word = try? NSRegularExpression(pattern: "\\b\(NSRegularExpression.escapedPattern(for: name))\\b")
        var users: [String] = []
        for file in knowledge.textFiles() where file.path.hasSuffix(".swift") && !RepoKnowledge.isNoise(file.path) && !exact.contains(where: { $0.span.file == file.path }) {
            if let line = file.lines.firstIndex(where: { word?.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }) { users.append("\(file.path):\(line + 1)") }
            if users.count >= 10 { break }
        }
        if !users.isEmpty { out.append("  used in: " + users.joined(separator: "; ")) }
        return out.joined(separator: "\n")
    }

    private static let literalPatterns: [(kind: String, regex: NSRegularExpression)] = {
        func make(_ kind: String, _ pattern: String) -> (String, NSRegularExpression) { (kind, try! NSRegularExpression(pattern: pattern)) }
        return [
            make("button", #"\bButton\(\s*"((?:[^"\\]|\\.)+)""#), make("text", #"\bText\(\s*"((?:[^"\\]|\\.)+)""#),
            make("label", #"\bLabel\(\s*"((?:[^"\\]|\\.)+)""#), make("field", #"\b(?:TextField|SecureField|TextEditor)\(\s*"((?:[^"\\]|\\.)+)""#),
            make("toggle", #"\b(?:Toggle|Picker|Section|Link|NavigationLink|Menu|DisclosureGroup)\(\s*"((?:[^"\\]|\\.)+)""#),
            make("title", #"\.(?:navigationTitle|navigationSubtitle|alert|confirmationDialog|help)\(\s*"((?:[^"\\]|\\.)+)""#),
            make("a11y-label", #"\.accessibilityLabel\(\s*"((?:[^"\\]|\\.)+)""#), make("a11y-id", #"\.accessibilityIdentifier\(\s*"((?:[^"\\]|\\.)+)""#),
            make("uikit", #"(?:setTitle\(\s*|\.(?:text|title|placeholder|accessibilityIdentifier|accessibilityLabel)\s*=\s*)"((?:[^"\\]|\\.)+)""#),
        ]
    }()

    /// The words a user can see or a test can target in a file or folder: titles, buttons, fields, accessibility labels and identifiers.
    static func uiStrings(_ knowledge: RepoKnowledge, path: String, limit: Int = 90) -> String {
        let prefix = path == "." || path.isEmpty ? "" : path
        let files = knowledge.textFiles().filter { $0.path.hasSuffix(".swift") && (prefix.isEmpty || $0.path == prefix || $0.path.hasPrefix(prefix.hasSuffix("/") ? prefix : prefix + "/")) }
        guard !files.isEmpty else { return "No Swift files under \(path)." }
        var out: [String] = []
        for file in files {
            var seen = Set<String>(), entries: [String] = []
            for (offset, line) in file.lines.enumerated() where line.contains("\"") {
                for (kind, regex) in literalPatterns {
                    for match in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                        guard let range = Range(match.range(at: 1), in: line) else { continue }
                        let text = String(line[range])
                        if text.count > 70 || !seen.insert("\(kind)|\(text)").inserted { continue }
                        entries.append("  \(offset + 1) \(kind): \(text)")
                    }
                }
            }
            if !entries.isEmpty { out.append(file.path); out += entries }
            if out.count >= limit { out.append("…(more; narrow the path)"); break }
        }
        return out.isEmpty ? "No UI strings found under \(path)." : out.joined(separator: "\n")
    }
}
