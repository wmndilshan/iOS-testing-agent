import Testing
import Foundation

/// Structure rules for the iOS capability platform (see TOOL_ARCHITECTURE.md).
@Suite("iOS capability architecture")
struct IOSCapabilityArchitectureTests {

    @Test("ToolRegistry contains no gesture implementation and no per-tool switch")
    func testRegistryHasNoGestureSwitch() {
        let registry = SourceTree.core.first { $0.name == "ToolRegistry.swift" }!.code
        for tool in ToolNames.all { #expect(!registry.contains("case \"\(tool)\""), "ToolRegistry must not switch on '\(tool)'") }
        for call in ["driver.tap(", "driver.swipe(", "driver.doubleTap(", "driver.longPress(", "driver.scroll(", "driver.typeText(", "driver.clearText(", "driver.dragAndDrop(", "driver.captureObservation("] {
            #expect(!registry.contains(call), "ToolRegistry must delegate to the executor, not call \(call)")
        }
        #expect(registry.split(separator: "\n").count < 260, "the registry stays orchestration-light")
    }

    @Test("Only iOS performers call driver gesture methods")
    func testDriverGestureCallsLiveOnlyInPerformers() {
        for file in SourceTree.core where !file.inLayer("Performers") && file.layer != "Infrastructure" {
            for call in ["driver.tap(", "driver.doubleTap(", "driver.longPress(", "driver.swipe(", "driver.scroll(", "driver.dragAndDrop(", "driver.typeText(", "driver.clearText("] {
                #expect(!file.code.contains(call), "\(file.path) must not perform a gesture (\(call))")
            }
        }
    }

    @Test("Performers conform in one folder and the typed-action switch is the only mapping")
    func testPerformerStructure() {
        let performers = SourceTree.core.filter { $0.code.contains(": IOSPerformable") }
        #expect(!performers.isEmpty && performers.allSatisfy { $0.inLayer("Performers") })
        let mappers = SourceTree.core.filter { $0.code.contains("var performer: any IOSPerformable") }
        #expect(mappers.map(\.name) == ["IOSInteractionExecutor.swift"])
    }

    @Test("Domain interaction models are pure data: no tools, drivers or file access")
    func testInteractionDomainIsPure() {
        for file in SourceTree.core where file.inLayer("Interaction") {
            #expect(file.layer == "Domain")
            for forbidden in ["ToolRegistry", "ToolCatalog", "DeviceDriver", "FileManager", "Process(", "URLSession", "AnyCodableValue", "[String: Any]"] {
                #expect(!file.symbols.contains(forbidden), "\(file.path) must stay pure: \(forbidden)")
            }
        }
    }

    @Test("iOS tool code cannot authorize, approve, launch processes or run xcodebuild")
    func testIOSToolsCannotAuthorizeOrLaunch() {
        for file in SourceTree.core where file.inLayer("iOS") {
            for forbidden in ["DispatchAuthorizer", "HITLApproval", "approveCurrentStep", "ApprovalPolicy", "Process(", "xcodebuild", "ScenarioExecutionController"] {
                #expect(!file.symbols.contains(forbidden), "\(file.path) must not reference \(forbidden)")
            }
        }
    }

    @Test("Actions are not dictionaries: nothing below the decoder sees raw arguments")
    func testNoRawArgumentsBelowTheDecoder() {
        for file in SourceTree.core where file.inLayer("Performers") || file.name == "IOSInteractionExecutor.swift" {
            #expect(!file.code.contains("[String: AnyCodableValue]") || file.name == "ObservationPerformers.swift", "\(file.path)")
            #expect(!file.code.contains("arguments"), "\(file.path) must not read raw arguments")
        }
    }

    @Test("There is exactly one waiting primitive and no sleeps outside the injected clock")
    func testSingleWaitingAbstraction() {
        for file in SourceTree.core where file.layer == "Application" || file.layer == "Domain" {
            let bareSleep = file.code.range(of: #"(?<!clock\.)(?<![A-Za-z])sleep\("#, options: .regularExpression) != nil
            #expect(!file.code.contains("Task.sleep") && !file.code.contains("usleep(") && !bareSleep, "\(file.path)")
        }
        let sleepers = SourceTree.core.filter { $0.code.contains("clock.sleep(") && $0.layer == "Application" }
        // IOSExecution's ConditionWaiter is the one waiter for device conditions. WorkflowScheduler additionally sleeps through
        // retry backoff on the same injected clock (never a real-time sleep); it executes no device action.
        #expect(Set(sleepers.map(\.name)).isSubset(of: ["IOSExecution.swift"]), "\(sleepers.map(\.name))")
    }

    @Test("A new tool needs a descriptor and a decoder, never a change to the trusted security spine")
    func testSecuritySpineDoesNotNameToolsOrCapabilities() {
        for file in SourceTree.core where ["DispatchAuthorizer.swift", "ApprovalPolicy.swift", "ScenarioStepDispatcher.swift"].contains(file.name) {
            for name in ToolNames.all { #expect(!file.symbols.contains("\"\(name)\""), "\(file.path) must be tool-agnostic: '\(name)'") }
            for forbidden in ["IOSAction", "TapAction", "ToolCatalog"] { #expect(!file.symbols.contains(forbidden), "\(file.path) must not know \(forbidden)") }
        }
        let driver = SourceTree.core.first { $0.name == "IDBDriver.swift" }!
        #expect(!driver.symbols.contains("ToolCatalog") && !driver.symbols.contains("IOSAction"), "the driver stays tool-agnostic")
    }
}

enum ToolNames {
    static let all = ["tap_element", "double_tap_element", "long_press_element", "swipe", "drag_and_drop", "type_text", "clear_text", "scroll",
                      "wait_for_element", "capture_screenshot", "get_accessibility_tree", "get_app_state", "get_element_details", "inspect_elements"]
}
