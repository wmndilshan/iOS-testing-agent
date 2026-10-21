import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("iOS capability catalog honesty")
struct IOSCatalogHonestyTests {

    @Test func testOnlyEvidenceBackedToolsClaimLiveVerification() {
        // Live evidence exists only for: tap, double tap, long press, type/clear text, scroll, drag, the accessibility tree
        // (fixture runs from 2026-09-20 on), select_tab (both directions, 2026-09-23) and capture_screenshot (the
        // read-only FIXTURE-SCREENSHOT run of 2026-09-25, execution BEA8C199), get_app_state (9C02C0FD) and
        // get_element_details (EB61E24A), both read-only fixture runs of 2026-09-25, and inspect_elements
        // (001E7D28, fixture Preview bridge run of 2026-10-01). Every entry is an allow-list decision:
        // promoting a tool means adding it here on purpose, with a recorded live run.
        let verified = Set(ToolCatalog.descriptors.filter { $0.live == .liveVerified }.map(\.name))
        #expect(verified == ["tap_element", "get_accessibility_tree", "double_tap_element", "long_press_element", "type_text", "clear_text", "scroll", "drag_and_drop", "select_tab", "dismiss_keyboard", "swipe", "capture_screenshot", "get_app_state", "get_element_details", "inspect_elements"])
    }



    @Test func testCanonicalNamesAreNamespacedAndUnique() {
        let names = ToolCatalog.descriptors.map(\.canonicalName)
        #expect(Set(names).count == names.count)
        for d in ToolCatalog.descriptors {
            #expect(d.canonicalName.hasPrefix(d.platform == .ios ? "ios." : "host."), "\(d.name) -> \(d.canonicalName)")
            #expect(d.canonicalName != d.name)
        }
    }

    @Test func testResolutionStillUsesTheStableNamesUntilAliasesAreIntroducedSafely() {
        for d in ToolCatalog.descriptors {
            #expect(ToolCatalog.descriptor(for: d.name) != nil)
            #expect(ToolCatalog.descriptor(for: d.canonicalName) == nil, "aliases are metadata only; accepting them needs a compatibility review")
        }
    }

    @Test func testEveryToolDeclaresAnOutputContractAndFreshObservationRulesFollowRisk() {
        for d in ToolCatalog.descriptors {
            #expect(!d.output.isEmpty)
            #expect(d.requiresFreshObservationAfter == (d.risk == .mutating) && d.requiresApproval == (d.risk == .mutating))
        }
    }

    @Test func testTheCapabilityMatrixDocumentMatchesTheCatalog() throws {
        let doc = try String(contentsOf: RepositoryRoot.url.appendingPathComponent("docs/IOS_CAPABILITY_MATRIX.md"), encoding: .utf8)
        for d in ToolCatalog.descriptors {
            let row = doc.split(separator: "\n").first { $0.contains("`\(d.canonicalName)`") }
            let line = try #require(row.map(String.init), "matrix has no row for \(d.canonicalName)")
            #expect(line.contains(d.live.rawValue) || (d.live == .simulationOnly && line.contains("SIMULATION_ONLY")), "\(d.canonicalName): \(d.live.rawValue) not in its matrix row")
        }
        #expect(!doc.contains("| SUPPORTED |"), "the word SUPPORTED without evidence is not allowed")
    }
}
