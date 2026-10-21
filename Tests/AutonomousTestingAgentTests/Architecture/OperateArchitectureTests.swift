import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// The Operate section adds a graph of agents and a live view that can be clicked. These pin that neither gains a way around the device lane:
/// the agents only request, the code agents only read, and the click handler can only call the Operate state.
@Suite("Operate architecture")
struct OperateArchitectureTests {
    private var graphFiles: [SourceTree.File] { SourceTree.all.filter { $0.path.hasPrefix("Sources/AgentEngine/Operate/") } }
    private var views: [SourceTree.File] { SourceTree.all.filter { $0.path.hasPrefix("Sources/GUI/Views/Operate/") } }
    private var presentation: [SourceTree.File] { SourceTree.core.filter { $0.path.hasPrefix("Sources/AgentPresentation/Operate/") } }

    @Test("The graph and the code agents start no process and write no file: the repository stays read-only")
    func graphReadsOnly() {
        #expect(!graphFiles.isEmpty)
        for file in graphFiles {
            for banned in ["Process()", "NSTask", "FileManager.default.createFile", ".write(to:", "removeItem", "forWritingAtPath", "moveItem", "copyItem"] {
                #expect(!file.symbols.contains(banned), "\(file.path) uses \(banned)")
            }
        }
    }

    @Test("Looking at the screen is read-only: read_screen, find, look and describe_screen never ask")
    func observationIsFree() {
        for kind in [DeviceCommandKind.readScreen, .find, .look, .describeScreen] {
            #expect(DeviceCommandCatalog.spec(for: kind).risk == .readOnly, Comment(rawValue: kind.rawValue))
        }
    }

    @Test("The Operate views and state never name idb or the executor: a click goes to the Operate state only")
    func clickGoesThroughTheState() {
        #expect(!views.isEmpty && !presentation.isEmpty)
        for file in views + presentation {
            for banned in ["IDBClient", "IDBDeviceControl", "Process()", "DeviceControlPolicy", "IDBCommandBuilder"] { #expect(!file.symbols.contains(banned), "\(file.path) names \(banned)") }
        }
        for file in views { #expect(!file.symbols.contains("DeviceControlling") && !file.symbols.contains("control.run("), "\(file.path)") }
        let panel = views.first { $0.name == "LivePanel.swift" }
        #expect(panel?.text.contains("operate.takeOverTap") == true)
    }

    @Test("The click handler is outside the audited mirror files: the mirror itself stays view-only")
    func mirrorStaysViewOnly() {
        let mirror = SourceTree.all.filter { $0.name == "SimulatorMirror.swift" || $0.name == "LivePreview.swift" }
        for file in mirror { #expect(!file.symbols.contains("SpatialTapGesture") && !file.symbols.contains("onTapGesture"), "\(file.path)") }
    }

    @Test("The take-over tap is run as the person but still validated: a person's command goes through the same validator")
    func humanPathValidates() {
        let handler = SourceTree.core.first { $0.name == "DeviceRequestHandler.swift" }!
        let pipeline = SourceTree.core.first { $0.name == "DeviceCommandPipeline.swift" }!
        #expect(handler.text.contains("pipeline.prepare") && handler.text.contains("func runAsPerson"), "a person's command is prepared (validated) like any other")
        #expect(pipeline.text.contains("DeviceCommandValidator.validate"))
    }

    @Test("Operate never reads a repository: no repository flag, index or sandbox in the state, the process entry or the graph")
    func noRepository() {
        let entry = SourceTree.all.filter { $0.name == "Engine+Operate.swift" }
        let state = SourceTree.core.filter { $0.path.hasPrefix("Sources/AgentPresentation/Operate/") }
        #expect(!entry.isEmpty && !state.isEmpty)
        for file in entry + state + graphFiles {
            for banned in ["--repo", "RepoKnowledge", "RepoSandbox", "CodeGuide", "RepoInsights", "CodeIntelligence", "AgentTools.repository"] {
                #expect(!file.text.contains(banned), "\(file.path) mentions \(banned)")
            }
        }
        #expect(!graphFiles.contains { $0.name == "CodeTeam.swift" })
    }
}
