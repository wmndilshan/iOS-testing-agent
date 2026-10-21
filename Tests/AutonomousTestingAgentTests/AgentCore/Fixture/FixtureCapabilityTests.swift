import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("Fixture scenarios and typed runner")
struct FixtureCapabilityTests {

    // MARK: Trusted catalog

    @Test func testEveryFixtureStepUsesACatalogedToolOfTheScenariosOwnRiskAndValidTrustedArguments() {
        for scenario in FixtureScenarioCatalog.shared.scenarios {
            #expect(scenario.id.hasPrefix("FIXTURE-"))
            #expect(FixtureScenarioCatalog.screen(for: scenario.id) != nil, "\(scenario.id) needs a provisioned screen")
            // A read-only scenario has nothing to restore, so it must not declare a teardown step.
            #expect(scenario.changesUIState || scenario.teardownStep == nil, "\(scenario.id): read-only scenarios have no teardown")
            for step in scenario.steps {
                let d = ToolCatalog.descriptor(for: step.toolName)
                if scenario.changesUIState {
                    #expect(d?.risk == .mutating, "\(step.id) must use a cataloged mutating tool")
                } else {
                    // The trusted validator admits only these tools into a read-only scenario, and the trusted
                    // catalog must agree that each one is read-only.
                    #expect(d?.risk == .readOnly, "\(step.id) must use a cataloged read-only tool")
                    #expect(SafeScenario.readOnlyScenarioTools.contains(step.toolName), "\(step.id) is not admissible in a read-only scenario")
                }
                #expect(step.verification != nil, "\(step.id) must verify deterministically")
                guard let d else { continue }
                // Trusted arguments plus the system-supplied fields must satisfy the tool's own schema.
                var args = step.trustedArguments
                for field in d.fieldNames where field == "snapshotID" || field.hasSuffix("ElementID") || field == "elementID" || field == "containerID" {
                    args[field] = .string(field == "snapshotID" ? "s" : "e")
                }
                #expect(ToolInputValidator().violation(of: d, arguments: args) == nil, "\(step.id): \(ToolInputValidator().violation(of: d, arguments: args) ?? "")")
            }
        }
    }

    /// The domain's read-only admission list and the trusted tool catalog must not drift apart.
    @Test func testTheReadOnlyScenarioToolListAgreesWithTheTrustedCatalog() {
        for name in SafeScenario.readOnlyScenarioTools {
            #expect(ToolCatalog.risk(of: name) == .readOnly, Comment(rawValue: "\(name) is not a read-only tool"))
        }
        #expect(SafeScenario.readOnlyScenarioTools.isDisjoint(with: ToolCatalog.mutatingTools))
    }

    @Test func testTrustedArgumentsAreNeverEncodedIntoStoredScenarioRecords() throws {
        let step = try #require(FixtureScenarioCatalog.shared.findScenario(by: "FIXTURE-TEXT")?.actionStep)
        #expect(step.trustedArguments["text"] != nil)
        let json = String(decoding: try JSONEncoder().encode(step), as: UTF8.self)
        #expect(!json.contains(FixtureScenarioCatalog.fixtureText) && !json.contains("trustedArguments"))
    }

    @Test func testStatusVerificationMatchesByLabelSoAStaleStatusCannotPass() throws {
        let v = try #require(FixtureScenarioCatalog.shared.findScenario(by: "FIXTURE-DOUBLE-TAP")?.actionStep.verification)
        func obs(_ label: String) -> Observation {
            ProductFixtures.observation("o-\(label)", [ProductFixtures.element("st", role: "staticText", identifier: "fixture.doubleTap.status", label: label)])
        }
        #expect(v.verify(in: obs("doubleTap:double-tapped")).verified)
        #expect(!v.verify(in: obs("doubleTap:idle")).verified)
        #expect(!v.verify(in: obs("doubleTap:single-tapped")).verified)
    }

    // MARK: Admission: trusted arguments are authoritative

    @Test @MainActor func testProposalCannotSupplyOrOverrideTrustedArgumentsAndTextComesOnlyFromTheStep() throws {
        let scenario = try #require(FixtureScenarioCatalog.shared.findScenario(by: "FIXTURE-TEXT"))
        let field = ProductFixtures.element("f1", role: "textField", identifier: "fixture.text.field")
        let obs = ProductFixtures.observation("snap", [field])
        let controller = ScenarioExecutionController(catalog: FixtureScenarioCatalog.shared, validator: TrustedActionValidator(catalog: FixtureScenarioCatalog.shared))
        controller.startScenario(scenario)
        controller.activeObservation = obs
        func proposal(_ args: [String: AnyCodableValue]) -> ActionProposal {
            ActionProposal(scenarioID: scenario.id, snapshotID: obs.snapshotID, elementID: "f1", expectedRole: "textField",
                           expectedIdentifier: "fixture.text.field", toolName: "type_text", arguments: args, reason: "r", stepIndex: 0, stepID: scenario.actionStep.id)
        }
        let attack = controller.handleProposal(proposal(["text": .string("attacker text")]))
        guard case .failure(let err) = attack, "\(err)".contains("trusted scenario argument") else { Issue.record("model-supplied text must be rejected for that reason: \(attack)"); return }
        let admitted = controller.handleProposal(proposal([:]))
        guard case .success(let request) = admitted else { Issue.record("clean proposal must be admitted: \(admitted)"); return }
        #expect(request.arguments["text"] == .string(FixtureScenarioCatalog.fixtureText))
    }

    // MARK: Typed text never leaks



    // MARK: Architecture


    @Test func testNoArbitraryCodeExecutionSurfaceInProductionSources() {
        for f in SourceTree.all {
            #expect(!f.symbols.contains("NSExpression"), Comment(rawValue: f.path))
            #expect(!f.symbols.contains("JavaScriptCore") && !f.symbols.contains("evaluateJavaScript"), Comment(rawValue: f.path))
            #expect(!f.symbols.contains("dlopen"), Comment(rawValue: f.path))
        }
    }
}
