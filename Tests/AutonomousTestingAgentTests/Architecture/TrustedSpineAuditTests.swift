import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// Source-level audit of the trusted execution spine and the layering rules in ARCHITECTURE_RULES.md.
///
/// The audit is layout-agnostic: it locates the repository by walking up to Package.swift, and it
/// identifies code by layer folder (a path component such as `Recovery`) or by type-file prefix
/// (`ScenarioExecutionController`), so splitting a type across extension files
/// or moving files inside a layer does not break it. Adding a new execution path does.
@Suite("52. Trusted Spine Source Audit Tests")
struct TrustedSpineAuditTests {

    typealias SourceFile = SourceTree.File
    private static let allSources = SourceTree.all

    private static func core() -> [SourceFile] { allSources.filter { SourceTree.coreModules.contains(($0.path.split(separator: "/").dropFirst().first).map(String.init) ?? "") } }
    private func count(_ needle: String, in text: String) -> Int { text.components(separatedBy: needle).count - 1 }
    private func names(_ files: [SourceFile]) -> String { files.map(\.path).joined(separator: ", ") }

    @Test("The audit can actually see the source tree")
    func testSourcesFound() {
        #expect(Self.allSources.count > 100)
        #expect(Self.core().count > 80)
    }

    // MARK: - Execution-path audit

    @Test("Recovery, observability and run-history code reference no tool registry, driver or process launcher")
    func testProductLayerHasNoExecutionAccess() {
        let product = Self.core().filter { ($0.inLayer("Recovery")) || $0.inLayer("Observability") }
        #expect(product.count >= 8)
        for file in product {
            for forbidden in ["ToolRegistry", "DeviceDriver", "SimulatedDriver", "Process(", ".execute(toolCall", "dispatchCurrentStep", "approveCurrentStep"] {
                #expect(!file.code.contains(forbidden), "\(file.path) must not reference '\(forbidden)'")
            }
        }
    }

    @Test("Recovery, observability and security code cannot approve or dispatch")
    func testAdvisoryComponentsCannotExecute() {
        let advisory = Self.core().filter { ["Recovery", "Observability", "Security"].contains(where: $0.inLayer) }
        #expect(advisory.count >= 20)
        for file in advisory {
            for forbidden in ["approveCurrentStep(", "dispatchCurrentStep(", ".execute(toolCall", "toolRegistry.execute"] {
                #expect(!file.code.contains(forbidden), "\(file.path) must not call '\(forbidden)'")
            }
        }
    }

    @Test("Domain and Security code never touch tools, drivers, processes, SwiftUI or XCTest")
    func testDomainAndSecurityArePure() {
        for file in Self.core() where file.inLayer("Domain") || file.inLayer("Security") {
            for forbidden in ["import SwiftUI", "import XCTest", "ToolRegistry", "DeviceDriver", "Process(", "FileManager"] {
                #expect(!file.code.contains(forbidden), "\(file.path) must not reference '\(forbidden)'")
            }
        }
    }

    @Test("SwiftUI is imported only by presentation code")
    func testSwiftUIConfinement() {
        for file in Self.core() where file.code.contains("import SwiftUI") {
            #expect(file.inLayer("Presentation"), "\(file.path) imports SwiftUI outside Presentation")
        }
    }

    @Test("Mutating tool execution has exactly one call site (the dispatcher); the UI may only run read-only tools")
    func testExecuteCallSites() {
        // Authorized execution: `toolRegistry.execute(<call>, authorization:` ...
        let authorized = Self.allSources.filter { $0.code.contains("toolRegistry.execute(") }
        #expect(authorized.map(\.isDispatcher) == [true], "Unexpected authorized-execute call sites: \(names(authorized))")
        #expect(authorized.reduce(0) { $0 + count("toolRegistry.execute(", in: $1.code) } == 1)
        #expect(authorized[0].code.contains("authorization: authorization"))
        // Read-only execution: the registry's own entry point is not called by any production code today.
        let readOnly = Self.allSources.filter { $0.code.contains(".executeReadOnly(") }
        #expect(readOnly.isEmpty, "Unexpected read-only call sites: \(names(readOnly))")
    }

    @Test("The dispatcher requires proof of authorization that only DispatchAuthorizer can create")
    func testDispatcherRequiresAuthorization() {
        let dispatcher = Self.core().first { $0.name == "ScenarioStepDispatcher.swift" }!
        #expect(dispatcher.code.contains("authorization: DispatchAuthorizer.Authorized"))
        let authorizer = Self.core().first { $0.name == "DispatchAuthorizer.swift" }!
        #expect(authorizer.code.contains("fileprivate init(observation: Observation,"))
        // Nobody else constructs the proof.
        let forgers = Self.allSources.filter { $0.name != "DispatchAuthorizer.swift" && $0.code.contains("DispatchAuthorizer.Authorized(") }
        #expect(forgers.isEmpty, "\(names(forgers))")
        // Only the controller instantiates the dispatcher.
        let users = Self.allSources.filter { $0.code.contains("ScenarioStepDispatcher()") }
        #expect(users.allSatisfy { $0.isController }, "\(names(users))")
    }

    @Test("dispatchCurrentStep is called only by the CLI, controller, and narrow Presentation adapter")
    func testDispatchCallers() {
        let callers = Self.allSources.filter { $0.code.contains("dispatchCurrentStep(") }
        #expect(!callers.isEmpty)
        #expect(callers.allSatisfy {
            $0.isController || $0.isCLI || $0.name == "TrustedExecutionPort.swift"
        }, "Unexpected dispatch callers: \(names(callers))")
    }

    @Test("approveCurrentStep has only explicit, human- or mode-gated callers")
    func testApprovalCallers() {
        let files = Self.allSources.filter { $0.code.contains("approveCurrentStep(source:") }
        #expect(files.allSatisfy { $0.isController || $0.isCLI }, "Unexpected approval callers: \(names(files))")
        let production = files.map(\.code).joined(separator: "\n")
        #expect(!production.contains("source: .testAuthority"), "Test authority must never be callable from production source.")
        let humanCalls = files.reduce(0) { $0 + count("approveCurrentStep(source: .human", in: $1.code) }
        let policyCalls = files.reduce(0) { $0 + count("approveCurrentStep(source: .explicitAutomationPolicy)", in: $1.code) }
        #expect(humanCalls == 1, "CLI stdin (requestSupervisorApproval) is the one human approval site.")
        #expect(policyCalls == 1, "The one disclosed scripted-policy site is requestSupervisorApproval for the non-human modes.")
    }

    @Test("Nothing launches xcodebuild or the removed generic smoke execution")
    func testXcodebuildLaunchPaths() {
        let files = Self.allSources
        #expect(!files.contains { $0.code.contains("/usr/bin/xcodebuild") }, "xcodebuild must not be spawned")
        #expect(!files.contains { $0.code.contains(".runSmokeTest(") })
        #expect(!files.contains { $0.name == "TestExecutionService.swift" }, "Unused execution service must stay deleted")
    }

    @Test("The --smoke mode and its Gemini function-call execution path stay removed")
    func testSmokeBypassStaysRemoved() {
        for file in Self.allSources {
            #expect(!file.text.contains("\"--smoke\""), "\(file.path) must not parse --smoke")
            #expect(!file.code.contains("runMilestone2SmokeTest"), "\(file.path)")
            #expect(!file.code.contains("executeSynchronously"), "\(file.path): no synchronous ToolRegistry dispatcher")
            #expect(!file.code.contains("runUISmokeTest"), "\(file.path): no model-facing smoke tool")
            #expect(!file.code.contains("run_ui_smoke_test"), "\(file.path)")
        }
        #expect(!Self.allSources.contains { $0.name == "Engine+SmokeTest.swift" })
    }

    @Test("ToolRegistry has no entry point that runs a call without classification or authorization")
    func testToolRegistryEntryPoints() {
        let registry = Self.core().first { $0.name == "ToolRegistry.swift" }!.code
        let signatures = registry.split(separator: "\n").filter { $0.contains("func execute") }.map { String($0) }
        #expect(signatures.count == 2, "\(signatures)")
        #expect(signatures.contains { $0.contains("func executeReadOnly(") })
        // Every other `func execute` must take the authorization proof.
        let authorized = registry.components(separatedBy: "public func execute(\n").dropFirst().first ?? ""
        #expect(authorized.contains("authorization: DispatchAuthorizer.Authorized"))
        #expect(!registry.contains("FunctionCall"))
        // The read-only entry point consults the static catalog.
        #expect(registry.contains("ToolCatalog.descriptor(for: toolCall.name)"))
    }

    @Test("No CLI runner executes tools directly or names Gemini wire types")
    func testCLIHasNoDirectExecution() {
        let wire = ["GenerateContentRequest", "FunctionDeclaration", "ToolDeclarationWrapper", "FunctionCall", "UsageMetadata", "Content(", "Part("]
        for file in Self.allSources where file.isCLI {
            for forbidden in [".execute(", ".executeReadOnly(", "verifyTestingOff"] where forbidden != "verifyTestingOff" {
                #expect(!file.code.contains(forbidden), "\(file.path) must not call ToolRegistry directly (\(forbidden))")
            }
            for name in wire { #expect(!file.symbols.contains(name), "\(file.path) names Gemini type '\(name)'") }
            #expect(!file.symbols.contains("ApprovalGate"), "\(file.path)")
        }
    }

    @Test("Application code depends on provider-neutral LLM types, never Gemini wire types")
    func testNoGeminiWireTypesOutsideInfrastructure() {
        let wire = ["GenerateContentRequest", "GenerateContentResponse", "FunctionDeclaration", "ToolDeclarationWrapper", "FunctionCall", "UsageMetadata", "ToolParameters", "ToolProperty"]
        for file in Self.core() where file.layer != "Infrastructure" {
            for name in wire {
                let whole = file.symbols.range(of: "\\b\(name)\\b", options: .regularExpression) != nil
                #expect(!whole, "\(file.path) must not name Gemini wire type '\(name)'")
            }
        }
    }

    @Test("The legacy coordinator execution path stays deleted")
    func testLegacyPathsGone() {
        for file in Self.allSources {
            #expect(!file.text.contains("func runTestCase"), "\(file.path)")
        }
    }

    // MARK: - Security invariants

    @Test("Dispatch authorization and approval TTL live in the Security layer")
    func testAuthorizationInSecurityLayer() {
        #expect(Self.core().contains { $0.inLayer("Security") && $0.name == "DispatchAuthorizer.swift" })
        #expect(Self.core().contains { $0.inLayer("Security") && $0.name == "ApprovalPolicy.swift" })
        // The controller must not re-implement a TTL literal.
        for file in Self.core() where file.isController {
            #expect(!file.code.contains("addingTimeInterval(120"), "\(file.path) must use ApprovalPolicy for the approval TTL")
        }
    }

    @Test("Only the composition root chooses the persistent .skills / .runs locations")
    func testPersistentPathsChosenByCompositionRoot() {
        let choosers = Self.allSources.filter { $0.code.contains("\".skills\"") || $0.code.contains("\".runs\"") || $0.code.contains("\".logs\"") || $0.code.contains("\".artifacts\"") }
        #expect(choosers.map(\.name) == ["InfrastructureFactory.swift"], "Persistent store paths must be chosen only by AppCompositionRoot: \(names(choosers))")
    }

    @Test("No source file prints any part of an API key")
    func testNoKeyPrinting() {
        for file in Self.allSources {
            #expect(!file.code.contains("apiKey.prefix"), "\(file.path)")
            #expect(!file.code.contains("apiKey.suffix"), "\(file.path)")
        }
    }
}
