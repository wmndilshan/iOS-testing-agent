import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition
@testable import AgentEngine

private func makeRepository() throws -> URL {
    let root = ProductFixtures.tempDir()
    let sources = root.appendingPathComponent("Sources")
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    try """
    import SwiftUI

    struct SavedListScreen: View {
        @State private var showFilter = false
        var body: some View {
            Button { showFilter = true } label: { Image("filter") }
                .accessibilityIdentifier("saved-display-filter-button")
                .sheet(isPresented: $showFilter) { SavedDisplayFilterDrawer() }
        }
    }
    """.write(to: sources.appendingPathComponent("SavedListScreen.swift"), atomically: true, encoding: .utf8)
    try "struct DiscoverView: View { var body: some View { NavigationLink { SavedListScreen() } label: { Text(\"Saved Lists\") } } }\n"
        .write(to: sources.appendingPathComponent("DiscoverView.swift"), atomically: true, encoding: .utf8)
    try "struct Unrelated { let x = 1 }\n".write(to: sources.appendingPathComponent("Unrelated.swift"), atomically: true, encoding: .utf8)
    return root
}

@Suite("Code terms")
struct CodeTermsTests {
    @Test("Identifiers, type names, quoted labels and title-case phrases are found; test words are not")
    func extraction() {
        let terms = CodeTerms.extract(from: ["Note the icon 'saved-display-filter-button', then tap it once. Verify the Display Filter menu (SavedDisplayFilterDrawer) shows 'Mine'."])
        #expect(terms.contains("saved-display-filter-button") && terms.contains("SavedDisplayFilterDrawer"))
        #expect(terms.contains("Mine") && terms.contains("Display Filter"))
        #expect(!terms.map { $0.lowercased() }.contains("verify") && !terms.contains("Note"))
        #expect(terms.first == "saved-display-filter-button", "identifiers come first")
    }

    @Test("Terms are unique, capped, and an unremarkable step gives none")
    func limits() {
        let many = (1...30).map { "item-number-\($0)" }.joined(separator: " ")
        #expect(CodeTerms.extract(from: [many, many]).count == CodeTerms.maximum)
        #expect(CodeTerms.extract(from: ["tap it then verify"]).isEmpty)
    }
}

@Suite("Code guide")
struct CodeGuideTests {
    @Test("The screen that holds the identifier is found, with its code and where it is used from")
    func findsTheScreen() throws {
        let root = try makeRepository()
        let guide = CodeGuide(root: root, projectRoot: ProductFixtures.tempDir())
        let facts = try #require(guide.facts(stepText: "Tap the configuration icon 'saved-display-filter-button'", expected: "The Display Filter drawer (SavedDisplayFilterDrawer) opens",
                                             failure: "Display Filter menu/sheet is not open", screenLabels: []))
        #expect(facts.contains("Sources/SavedListScreen.swift:") && facts.contains("(SavedListScreen)"))
        #expect(facts.contains(".sheet(isPresented: $showFilter)"), "the code that presents the drawer is included")
        #expect(facts.contains("used from:") && facts.contains("DiscoverView.swift"))
        #expect(!facts.contains("Unrelated.swift"))
        #expect(facts.count <= CodeGuide.maxCharacters)
    }

    @Test("A step the source says nothing about gives no facts")
    func nothingFound() throws {
        let guide = CodeGuide(root: try makeRepository(), projectRoot: ProductFixtures.tempDir())
        #expect(guide.facts(stepText: "Tap 'nonexistent-widget-id'", expected: "", failure: nil, screenLabels: []) == nil)
    }

    @Test("Test and generated folders are not evidence")
    func skipsNoise() throws {
        let root = try makeRepository()
        let tests = root.appendingPathComponent("AppTests")
        try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
        try "let id = \"only-in-tests-identifier\"\n".write(to: tests.appendingPathComponent("T.swift"), atomically: true, encoding: .utf8)
        let guide = CodeGuide(root: root, projectRoot: ProductFixtures.tempDir())
        #expect(guide.facts(stepText: "Tap 'only-in-tests-identifier'", expected: "", failure: nil, screenLabels: []) == nil)
    }

    @Test("The planner note carries the facts after the judge's feedback")
    func note() {
        let note = PlannerNotes.actionNote(stepText: "Tap it", done: [], judgeFeedback: "menu not open", codeFacts: "Facts from the app's source code: X")
        #expect(note.hasSuffix("Facts from the app's source code: X") && note.contains("menu not open"))
        #expect(PlannerNotes.actionNote(stepText: "Tap it", done: [], judgeFeedback: nil).contains("Facts from") == false)
    }
}
