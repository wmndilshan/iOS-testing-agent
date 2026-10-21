import Testing
import Foundation

/// Rules for the tool platform and for future external integrations (see TOOL_ARCHITECTURE.md).
@Suite("Tool platform architecture")
struct ToolPlatformArchitectureTests {

    private func wholeWord(_ name: String, in text: String) -> Bool {
        text.range(of: "\\b\(name)\\b", options: .regularExpression) != nil
    }

    @Test("Tool descriptors are declared only in the trusted ToolCatalog")
    func testDescriptorsAreTrustedData() {
        for file in SourceTree.all where file.name != "ToolCatalog.swift" && file.name != "ToolDescriptor.swift" {
            #expect(!file.code.contains("ToolDescriptor("), "\(file.path) must not declare tools; add a descriptor to ToolCatalog")
        }
        let catalog = SourceTree.core.first { $0.name == "ToolCatalog.swift" }!
        #expect(catalog.layer == "Application" && catalog.code.contains("public static let descriptors"))
    }

    @Test("Tool code cannot create, change or consume approval state")
    func testToolsCannotTouchApproval() {
        for file in SourceTree.core where file.inLayer("Tools") {
            for forbidden in ["approveCurrentStep", "denyCurrentStep", "activeApproval", "HITLApprovalStatus", "HITLApprovalRequest", "ApprovalPolicy", "DispatchAuthorizer.Authorized("] {
                #expect(!file.symbols.contains(forbidden), "\(file.path) must not reference '\(forbidden)'")
            }
        }
        // The only Tools reference to the authorizer is the proof type ToolRegistry demands.
        let users = SourceTree.core.filter { $0.inLayer("Tools") && wholeWord("DispatchAuthorizer", in: $0.symbols) }
        #expect(users.map(\.name) == ["ToolRegistry.swift"])
    }

    @Test("Infrastructure adapters (current and future) can never authorize, approve or dispatch")
    func testInfrastructureCannotAuthorizeOrDispatch() {
        for file in SourceTree.core where file.layer == "Infrastructure" {
            for forbidden in ["approveCurrentStep", "dispatchCurrentStep", "DispatchAuthorizer", "handleProposal", "ScenarioExecutionController", "HITLApprovalRequest"] {
                #expect(!wholeWord(forbidden, in: file.symbols), "\(file.path) must not reference '\(forbidden)'")
            }
        }
    }

    @Test("SwiftUI views and presentation code never call a network provider")
    func testUINeverCallsProviders() {
        for file in SourceTree.all where file.path.hasPrefix("Sources/GUI/") || file.layer == "Presentation" {
            for forbidden in ["URLSession", "URLRequest", "LLMGateway", "URLSessionTransport", "LLMClient("] {
                #expect(!file.code.contains(forbidden), "\(file.path) must not reach a provider directly (\(forbidden))")
            }
        }
    }

    @Test("Application and Domain name no network, vendor or process API")
    func testApplicationAndDomainAreVendorFree() {
        for file in SourceTree.core where file.layer == "Application" || file.layer == "Domain" {
            for forbidden in ["URLSession", "URLRequest", "import Network", "Process()", "GenerateContent", "Gemini"] {
                let ok = forbidden == "Gemini" && file.text.contains("Gemini") && !file.code.contains(forbidden)  // prose in comments only
                #expect(ok || !file.code.contains(forbidden), "\(file.path) must stay vendor-free: \(forbidden)")
            }
        }
    }

    @Test("Removed duplicate typed-argument DTOs and unused outcome enum stay removed")
    func testDeadDuplicatesStayRemoved() {
        for file in SourceTree.all {
            for gone in ["TapElementArguments", "SwipeArguments", "TypeTextArguments", "DragAndDropArguments", "StepExecutionOutcome", "toolsWrapper", "ToolDeclarationWrapper("] where file.layer != "Infrastructure" {
                #expect(!file.symbols.contains(gone), "\(file.path) reintroduces '\(gone)'")
            }
        }
    }

    @Test("Every tool a scenario step uses is a classified catalog tool")
    func testScenarioToolsAreCatalogued() {
        let used = SourceTree.core.first { $0.name == "ScenarioCatalog.swift" }!.code
        let rx = try! NSRegularExpression(pattern: #"toolName:\s*"([a-z_]+)""#)
        let ns = used as NSString
        let names = Set(rx.matches(in: used, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) })
        #expect(!names.isEmpty)
        let catalog = SourceTree.core.first { $0.name == "ToolCatalog.swift" }!.code
        for name in names { #expect(catalog.contains("name: \"\(name)\""), "scenario tool '\(name)' is not in ToolCatalog") }
    }

    @Test("Artifacts and run history carry no authority: authorization and admission never reference them")
    func testArtifactsAndHistoryAreNotAuthorization() {
        for file in SourceTree.core where file.name == "DispatchAuthorizer.swift" || file.name == "ApprovalPolicy.swift" || file.name == "ProposalAdmission.swift" {
            for forbidden in ["Artifact", "RunHistory", "RunTrace"] {
                #expect(!file.symbols.contains(forbidden), "\(file.path) must not depend on \(forbidden)")
            }
        }
        // The dispatcher only forwards `ArtifactAssociation` (write-only run/scenario/step labels) so evidence can be
        // attached to the right run. It never reads an artifact, history or trace.
        let dispatcher = SourceTree.core.first { $0.isDispatcher }!
        let identifiers = dispatcher.symbols.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.contains("Artifact") }
        #expect(Set(identifiers) == ["ArtifactAssociation"], "\(Set(identifiers))")
        for forbidden in ["RunHistory", "RunTrace"] { #expect(!dispatcher.symbols.contains(forbidden)) }
    }
}
