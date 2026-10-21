import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// Source audit of the interactive simulator mirror.
///
/// The mirror is a projection of the real simulator and a proposal-only control surface. These tests
/// keep it that way: it reaches the rest of the system only through `SimulatorInteractionPort` (to
/// propose) and `SimulatorFramebufferSource` (to read pixels), and it contains no process, no
/// xcodebuild, no XCTest, no tool registry, no approval or dispatch call and no persistence.
@Suite("61. Simulator Mirror Architecture & Security Audit")
struct MirrorArchitectureTests {

    /// Every file that implements the mirror, in any layer or target.
    private static let mirrorFiles: [SourceTree.File] = SourceTree.all.filter { f in
        (f.inLayer("Presentation") && (f.name.hasPrefix("Mirror") || f.name == "SimulatorMirror.swift"))
            || f.path.hasPrefix("Sources/GUI/Views/Simulator/") || f.name == "LivePreview.swift"
    }

    private static let viewFiles = mirrorFiles.filter { $0.path.hasPrefix("Sources/GUI/") }

    @Test("The audit sees the mirror")
    func testFilesFound() {
        let names = Set(Self.mirrorFiles.map(\.name))
        for expected in ["MirrorFrameFingerprint.swift", "SimulatorMirror.swift", "LivePreview.swift", "SimulatorView.swift"] {
            #expect(names.contains(expected), "missing \(expected)")
        }
    }



    @Test("Mirror code launches no process, shell, xcodebuild, simctl or XCTest")
    func testNoProcessOrToolchain() {
        for file in Self.mirrorFiles {
            for forbidden in ["Process(", "NSTask", "posix_spawn", "system(", "NSAppleScript", "/bin/sh", "/bin/zsh",
                              "xcodebuild", "\"simctl\"", "xcrun", "import XCTest", "XCUIApplication",
                              "dlopen", "NSExpression"] {
                #expect(!file.code.contains(forbidden), "\(file.path) must not contain '\(forbidden)'")
            }
        }
    }

    @Test("Mirror code never reaches the tool registry, driver or authorization proof")
    func testNoExecutionAccess() {
        for file in Self.mirrorFiles {
            for forbidden in ["ToolRegistry", "toolRegistry", "executeReadOnly", ".execute(", "DeviceDriver",
                              "IDBDriver", "SimulatedDriver", "DispatchAuthorizer", "ScenarioStepDispatcher",
                              "LiveExecutionControllable"] {
                #expect(!file.symbols.contains(forbidden), "\(file.path) must not reference '\(forbidden)'")
            }
        }
    }

    @Test("Mirror code never approves or dispatches: Interact is input, not auto-approval")
    func testNoApprovalBypass() {
        for file in Self.mirrorFiles {
            for forbidden in ["approveCurrentStep", "dispatchCurrentStep", "approveScenarioAction", "approveScenarioTeardown",
                              "dispatchScenarioAction", "dispatchScenarioTeardown", ".status = .approved", "autoApprove"] {
                #expect(!file.code.contains(forbidden), "\(file.path) must not contain '\(forbidden)'")
            }
        }
    }

    @Test("Views talk to the controller and the port, never to AgentUIState's execution API")
    func testViewsUseThePort() {
        for file in Self.viewFiles {
            for forbidden in ["handleActionProposal", "submitInteraction(", "fetchAccessibilityTree(forceLive: false"] {
                #expect(!file.code.contains(forbidden), "\(file.path) must go through MirrorInteractionController ('\(forbidden)')")
            }
        }
    }


    @Test("Frame capture is read-only, lives in Infrastructure and is injected by composition")
    func testFramebufferBoundary() {
        let capture = SourceTree.core.first { $0.name == "SimctlFramebufferCapture.swift" }!
        #expect(capture.inLayer("Infrastructure"))
        #expect(capture.code.contains("[\"simctl\", \"io\", udid, \"screenshot\", \"--type=jpeg\", url.path]"),
                "the argument vector is fixed apart from a validated UDID and a private temp path")
        for verb in ["\"boot\"", "\"shutdown\"", "\"install\"", "\"launch\"", "\"spawn\"", "\"sendkey\"", "\"ui\"", "\"openurl\""] {
            #expect(!capture.code.contains(verb), "frame capture must not issue \(verb)")
        }
        let source = SourceTree.core.first { $0.name == "SimulatorFramebufferSource.swift" }!
        // One read operation; `stop()` only lets go of the stream that feeds it and has no way to act on the device.
        let operations = source.code.split(separator: "\n").filter { $0.contains("func ") }.map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(operations.filter { $0.contains("captureFrame") }.count == 1 && operations.filter { !$0.contains("captureFrame") && !$0.contains("func stop()") }.isEmpty, "\(operations)")
        // Presentation never constructs it; only the composition root does.
        let constructors = SourceTree.all.filter { $0.code.contains("SimctlFramebufferCapture()") }.map(\.name)
        #expect(Set(constructors).isSubset(of: ["InfrastructureFactory.swift"]), "\(constructors)")
    }

    @Test("Automation never depends on the mirror")
    func testAutomationIndependence() {
        let mirrorTypes = ["SimulatorMirror",                            "SimulatorPaneModel", "SimulatorInteractionPort", "SimulatorFramebufferSource"]
        for file in SourceTree.core where ["Orchestration", "Tools", "Recovery", "Security", "Domain"].contains(where: { file.inLayer($0) }) {
            for name in mirrorTypes {
                #expect(!file.symbols.contains(name), "\(file.path) must not depend on \(name)")
            }
        }
    }

    @Test("Mirror code persists nothing and never retries a mutating request")
    func testNoPersistenceOrRetry() {
        for file in Self.mirrorFiles {
            for forbidden in ["write(to", "createFile", "Keychain", "SecItem", "UserDefaults.standard.set", "ProcessInfo.processInfo.environment"] {
                #expect(!file.code.contains(forbidden), "\(file.path) must not contain '\(forbidden)'")
            }
        }
        // Mirror code has no retry.
        for file in Self.mirrorFiles {
            #expect(!file.code.lowercased().contains("retry"), "\(file.path)")
        }
    }

    @Test("No fake state authority: the mirror never builds a UI tree, navigation or element identities of its own")
    func testNoFakeState() {
        for file in Self.mirrorFiles {
            for pattern in [#"\bUIElementSnapshot\("#, #"\bObservation\("#, #"\bElementFrame\("#, "NavigationStack", "fakeScreen", "optimistic"] {
                #expect(file.code.range(of: pattern, options: .regularExpression) == nil, "\(file.path) must not fabricate state ('\(pattern)')")
            }
        }
    }
}
