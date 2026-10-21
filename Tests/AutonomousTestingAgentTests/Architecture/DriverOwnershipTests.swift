import Testing
import Foundation

/// Who may build, hold or name the concrete idb driver.
///
/// The trusted composition boundary is `App/` (AppCompositionRoot) plus `Infrastructure/`. Everything
/// else receives `DeviceDriver`. The concrete types are also
/// module-internal, so other targets cannot name them at all; these tests keep it that way.
@Suite("Driver ownership and legacy quarantine")
struct DriverOwnershipTests {

    private func wholeWord(_ name: String, in text: String) -> Bool {
        text.range(of: "\\b\(name)\\b", options: .regularExpression) != nil
    }
    private func names(_ files: [SourceTree.File]) -> String { files.map(\.path).joined(separator: ", ") }
    private static let trustedWiring: Set<String> = ["App", "Infrastructure"]

    @Test("The concrete IDBDriver is named only by Infrastructure and the composition root")
    func testConcreteDriverIsNamedOnlyByWiring() {
        for file in SourceTree.all {
            guard wholeWord("IDBDriver", in: file.symbols) else { continue }
            #expect(Self.trustedWiring.contains(file.layer ?? ""), "\(file.path) must use DeviceDriver, not the concrete driver")
        }
        let sites = SourceTree.all.filter { $0.code.range(of: "\\bIDBDriver\\(", options: .regularExpression) != nil }
        #expect(sites.allSatisfy { ["InfrastructureFactory.swift", "IDBDriver.swift"].contains($0.name) }, "\(names(sites))")
        let root = SourceTree.core.first { $0.name == "InfrastructureFactory.swift" }!.code
        #expect(root.contains("-> (any LiveExecutionControllable)?"))
    }

    @Test("Only wiring layers construct a ToolRegistry: no second registry inside application logic")
    func testToolRegistryConstructionSites() {
        let sites = SourceTree.all.filter { $0.code.contains("ToolRegistry(") && !$0.code.contains("class ToolRegistry") }
        for file in sites {
            let ok = Self.trustedWiring.contains(file.layer ?? "") || file.isCLI
            #expect(ok, "\(file.path) must receive a ToolRegistry from composition")
        }
        #expect(SourceTree.core.first { $0.name == "ToolRegistry.swift" }!.code.contains("driver: any DeviceDriver"))
    }

    @Test("Application depends on the driver port; nothing above Infrastructure can obtain a driver")
    func testOnlyPortsAreVisibleToApplicationLogic() {
        let dispatcher = SourceTree.core.first { $0.isDispatcher }!
        #expect(dispatcher.code.contains("any DeviceDriver"))
        let driverNames = ["DeviceDriver", "LiveExecutionControllable", "SimulatedDriver", "IDBDriver", "ToolRegistry"]
        let blind: [(String, (SourceTree.File) -> Bool)] = [
            ("Domain", { $0.layer == "Domain" }),
            ("Security", { $0.layer == "Security" }),
            ("Observability", { $0.layer == "Observability" }),
            ("Recovery", { $0.inLayer("Recovery") }),
            ("LLM pipeline", { $0.inLayer("Pipelines") || $0.inLayer("LLMPolicy") }),
            ("LLM infrastructure", { $0.inLayer("LLM") && $0.layer == "Infrastructure" }),
            ("Proposal admission", { $0.name == "ProposalAdmission.swift" }),
        ]
        for (label, matches) in blind {
            let files = SourceTree.core.filter(matches)
            #expect(!files.isEmpty, "\(label) layer not found")
            for file in files {
                for name in driverNames {
                    #expect(!wholeWord(name, in: file.symbols), "\(label): \(file.path) must not obtain a driver (\(name))")
                }
            }
        }
    }

    @Test("The controller never constructs the driver or a registry")
    func testControllerDoesNotConstructExecutionInfrastructure() {
        for file in SourceTree.core where file.isController {
            for forbidden in ["IDBDriver", "ToolRegistry(", "SimulatedDriver("] {
                #expect(!file.symbols.contains(forbidden), "\(file.path) must not construct \(forbidden)")
            }
        }
    }

    @Test("Presentation cannot obtain a raw driver or launch a Process")
    func testPresentationHasOnlyNarrowExecutionPorts() {
        for file in SourceTree.core where file.layer == "Presentation" {
            for forbidden in ["DeviceDriver", "LiveExecutionControllable", "ToolRegistry", "Process("] {
                #expect(!file.code.contains(forbidden), "\(file.path) gained privileged Presentation access: \(forbidden)")
            }
            #expect(file.code.range(of: "\\.driver\\b", options: .regularExpression) == nil,
                    "\(file.path) gained raw driver property access")
        }
        let registry = SourceTree.core.first { $0.name == "ToolRegistry.swift" }!.code
        #expect(registry.contains("private let driver: any DeviceDriver"))
        #expect(!registry.contains("public let driver"))
    }

    // MARK: Legacy

    @Test("The legacy ApprovalGate and its DTOs are gone, and nothing reintroduces an approval gate outside trusted approval")
    func testApprovalGateStaysDeleted() {
        for file in SourceTree.all {
            for gone in ["ApprovalGate", "ApprovalRequest", "ApprovalDecision", "ApprovalError", "requiresApproval("] {
                #expect(!wholeWord(gone, in: file.symbols) && !(gone.hasSuffix("(") && file.symbols.contains(gone)),
                        "\(file.path) reintroduces removed legacy approval type '\(gone)'")
            }
        }
        #expect(!SourceTree.all.contains { $0.components.contains("Approval") && $0.layer == "Legacy" })
    }
}
