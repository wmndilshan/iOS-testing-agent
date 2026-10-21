import Testing
import Foundation

/// Enforces the dependency direction between `AgentCore` layers (see ARCHITECTURE_RULES.md).
///
/// A type is attributed to the layer that declares it. A file may reference types only from its
/// own layer or a layer in `allowed`. The matrix is a ratchet: it lists today's legitimate edges,
/// and a new edge must be a deliberate change here plus a note in the architecture docs.
@Suite("56. Layer Dependency Direction Tests")
struct LayerDependencyTests {

    static let allowed: [String: Set<String>] = [
        "Shared":         [],
        "Domain":         ["Shared"],
        "Security":       ["Domain", "Shared"],
        "Observability":  ["Domain", "Security", "Shared"],
        "Application":    ["Domain", "Security", "Observability", "Shared"],
        "Infrastructure": ["Application", "Domain", "Security", "Observability", "Shared"],
        "Presentation":   ["Application", "Domain", "Observability", "Security", "Shared"],
        "App":            ["Application", "Domain", "Infrastructure", "Presentation", "Security", "Shared"],
    ]

    private static let declaration = try! NSRegularExpression(
        pattern: #"^\s*(?:public |internal |final |private |fileprivate )*(?:struct|class|enum|actor|protocol|typealias)\s+([A-Za-z0-9_]+)"#,
        options: [.anchorsMatchLines])

    /// Type name -> declaring layer, for names declared in exactly one layer.
    private static let typeLayers: [String: String] = {
        var seen: [String: Set<String>] = [:]
        for file in SourceTree.core {
            guard let layer = file.layer else { continue }
            let ns = file.text as NSString
            for m in declaration.matches(in: file.text, range: NSRange(location: 0, length: ns.length)) {
                seen[ns.substring(with: m.range(at: 1)), default: []].insert(layer)
            }
        }
        return seen.compactMapValues { $0.count == 1 && $0.first != nil ? $0.first : nil }.filter { $0.key.count > 4 }
    }()

    @Test("The layer map covers the whole tree")
    func testLayersKnown() {
        let layers = Set(SourceTree.core.compactMap(\.layer))
        #expect(layers == Set(Self.allowed.keys), "Layers found: \(layers.sorted())")
        #expect(Self.typeLayers.count > 200)
    }

    @Test("Every layer references only layers it is allowed to depend on")
    func testDependencyDirection() throws {
        let identifier = try NSRegularExpression(pattern: #"\b[A-Z][A-Za-z0-9_]+\b"#)
        var violations: [String: Set<String>] = [:]
        for file in SourceTree.core {
            guard let layer = file.layer, let ok = Self.allowed[layer] else { continue }
            let code = file.symbols as NSString
            var names = Set<String>()
            for m in identifier.matches(in: file.symbols, range: NSRange(location: 0, length: code.length)) {
                names.insert(code.substring(with: m.range))
            }
            for name in names {
                guard let target = Self.typeLayers[name], target != layer, !ok.contains(target) else { continue }
                violations["\(layer) -> \(target)  (\(file.name))", default: []].insert(name)
            }
        }
        #expect(violations.isEmpty, "Forbidden layer dependencies: \(violations.sorted { $0.key < $1.key })")
    }

    @Test("Application code never names concrete infrastructure or SwiftUI")
    func testApplicationIsInfrastructureFree() {
        for file in SourceTree.core where file.layer == "Application" {
            #expect(!file.code.contains("import SwiftUI"), "\(file.path)")
            #expect(!file.code.contains("URLSession"), "\(file.path) must not use the network directly")
            #expect(!file.code.contains("Process()"), "\(file.path) must not launch processes")
        }
    }

    @Test("Only the App layer constructs concrete infrastructure for the presentation layer")
    func testPresentationDoesNotConstructInfrastructure() {
        for file in SourceTree.core where file.layer == "Presentation" {
            for forbidden in ["IDBDriver(", "LLMClient(", "RunHistoryStore(", "Configuration.load"] {
                #expect(!file.code.contains(forbidden), "\(file.path) must receive '\(forbidden)' from the composition root")
            }
        }
    }

    @Test("The removed legacy approval gate and coordinator stay gone")
    func testLegacyStaysGone() {
        for file in SourceTree.core {
            #expect(!file.symbols.contains("ApprovalGate") && !file.symbols.contains("AgentCoordinator"), "\(file.path)")
        }
    }
}
