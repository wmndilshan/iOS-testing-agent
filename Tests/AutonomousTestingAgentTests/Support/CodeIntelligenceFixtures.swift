import Foundation
@testable import CodeIntelligence

/// Inline Swift sources and temporary repository trees for the CodeIntelligence suites. Nothing here reads the real
/// repository; trees live in unique temporary directories.
enum CodeIntelligenceFixtures {

    /// Indexes `files` (repository-relative path -> source) the same way the scanner does.
    static func index(_ files: [String: String]) -> ASTIndex {
        var index = ASTIndex()
        for (path, source) in files.sorted(by: { $0.key < $1.key }) {
            let (module, role) = RepositoryScanner.classify(path)
            let r = SwiftFileIndexer.index(path: path, module: module, role: role, source: source)
            index.add(file: r.file, declarations: r.declarations)
        }
        return index
    }

    static func declarations(_ source: String, path: String = "Sources/Core/File.swift") -> [Declaration] {
        let (module, role) = RepositoryScanner.classify(path)
        return SwiftFileIndexer.index(path: path, module: module, role: role, source: source).declarations
    }

    static func declaration(_ id: String, in source: String, path: String = "Sources/Core/File.swift") -> Declaration? {
        declarations(source, path: path).first { $0.id.rawValue == id }
    }

    /// Writes a tree into a new temporary directory and returns its URL. Remove it with `remove(_:)`.
    static func tree(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ci-\(UUID().uuidString)")
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    static func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    // MARK: A small package used by several suites

    static let store = """
    import Foundation

    public enum StoreError: Error { case missing, corrupt }

    public actor RecordStore {
        private var records: [String: Data] = [:]
        public private(set) var state: StoreState = .closed

        public init() {}

        public func save(_ data: Data, forKey key: String) throws {
            guard state == .open else { throw StoreError.missing }
            records[key] = data
        }

        public func load(_ key: String) throws -> Data {
            guard let d = records[key] else { throw StoreError.missing }
            return d
        }
    }

    public enum StoreState { case open, closed }
    """

    static let service = """
    public struct Importer {
        let store: RecordStore
        public func importAll(_ items: [String: Data]) async throws {
            for (k, v) in items { try await store.save(v, forKey: k) }
        }
    }
    """

    static let storeTests = """
    import Testing
    import Foundation
    @testable import Core

    @Suite("Record store")
    struct RecordStoreTests {
        let store = RecordStore()

        @Test("Saved data loads back") func testSaveThenLoadRoundTrip() async throws {
            try await store.save(Data([1]), forKey: "a")
            #expect(try await store.load("a") == Data([1]))
        }

        @Test func testLoadOfMissingKeyThrows() async {
            await #expect(throws: StoreError.self) { try await store.load("nope") }
        }
    }
    """

    static var package: [String: String] {
        ["Sources/Core/RecordStore.swift": store, "Sources/Core/Importer.swift": service, "Tests/CoreTests/RecordStoreTests.swift": storeTests]
    }
}
