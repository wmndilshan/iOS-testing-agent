import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition
@testable import AgentEngine

private func observation(_ elements: [UIElementSnapshot]) -> Observation {
    Observation(snapshotID: "snap_1", bundleID: "com.apple.mobilesafari", appState: .runningForeground, elements: elements)
}

@Suite("Step recovery policy")
struct StepRecoveryPolicyTests {
    @Test("No observation means the app is not reachable; a normal screen needs nothing")
    func basics() {
        #expect(StepRecoveryPolicy.assess(nil, isLoginStep: false) == .appNotReachable)
        #expect(StepRecoveryPolicy.assess(observation([UIElementSnapshot(id: "e1", role: "button", label: "Collection")]), isLoginStep: false) == .none)
    }

    @Test("A password field in the middle of a case, or an expiry message, means the session ended; not while on a login step")
    func loggedOut() {
        let login = observation([UIElementSnapshot(id: "e1", role: "textField", label: "Username"), UIElementSnapshot(id: "e2", role: "secureTextField", label: "Password")])
        #expect(StepRecoveryPolicy.assess(login, isLoginStep: false) == .loggedOut)
        #expect(StepRecoveryPolicy.assess(login, isLoginStep: true) == .none)
        let expired = observation([UIElementSnapshot(id: "e1", role: "staticText", label: "Your session has expired. Please log in again to continue.")])
        #expect(StepRecoveryPolicy.assess(expired, isLoginStep: false) == .loggedOut)
    }

    @Test("Login steps run from the username step to the step after the password step; none without a password step")
    func loginSteps() {
        func steps(_ texts: [String]) -> [CaseStep] { texts.enumerated().map { CaseStep(number: $0.offset + 1, text: $0.element) } }
        let withLogin = steps(["Launch the app", "Enter the username. Test Data: tester", "Enter the password [CREDENTIALS]", "Tap Log In", "Open Discover"])
        #expect(StepRecoveryPolicy.loginSteps(in: withLogin).map(\.number) == [2, 3, 4])
        #expect(StepRecoveryPolicy.loginSteps(in: steps(["Open Safari", "Tap search"])).isEmpty)
        let last = steps(["Enter the username", "Enter the password [CREDENTIALS]"])
        #expect(StepRecoveryPolicy.loginSteps(in: last).map(\.number) == [1, 2])
    }

    @Test("--retries defaults to one and can be turned off")
    func retriesFlag() {
        #expect(CaseRunFlags(args: ["--run-case=A"]).retries == 1)
        #expect(CaseRunFlags(args: ["--retries=0"]).retries == 0)
        #expect(CaseRunFlags(args: ["--retries=-3"]).retries == 0)
        #expect(CaseRunFlags(args: ["--retries=2"]).retries == 2)
    }
}

@Suite("Report of a stopped run")
struct StoppedRunReportTests {
    private func report() -> CaseRunReport {
        var r = CaseRunReport(testKey: "K-1", title: "T", mode: "LIVE", steps: [
            CaseRunReport.Step(id: "1.a", sourceStepNumber: 1, intent: "one", action: "tap", status: .passed),
            CaseRunReport.Step(id: "2.a", sourceStepNumber: 2, intent: "two", action: "tap", status: .failed),
        ])
        r.plannedSteps = (1...4).map { CaseRunReport.PlannedStep(number: $0, text: "step \($0)") }
        r.bundleID = "com.apple.mobilesafari"
        r.startStep = 1
        return r
    }

    @Test("Steps the run never reached get a skipped row that says where it stopped; steps outside the range do not")
    func unreached() {
        var r = report()
        r.addUnreachedRows(in: 1...3, reason: "not reached: the run stopped at step 2")
        #expect(r.steps.filter { $0.status == .skipped }.map(\.sourceStepNumber) == [3])
        #expect(r.steps.first { $0.sourceStepNumber == 3 }?.detail == "not reached: the run stopped at step 2")
        #expect(r.firstFailedStep == 2)
    }

    @Test("The new fields round-trip, and a report written before them still reads")
    func codable() throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var r = report(); r.failedStep = 2
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(CaseRunReport.self, from: try encoder.encode(r))
        #expect(back.bundleID == "com.apple.mobilesafari" && back.failedStep == 2 && back.plannedSteps?.count == 4)

        let old = #"{"testKey":"K","title":"T","mode":"LIVE","startedAt":"2026-10-14T10:00:00Z","steps":[],"outcome":"PASSED"}"#
        let decoded = try decoder.decode(CaseRunReport.self, from: Data(old.utf8))
        #expect(decoded.bundleID == nil && decoded.plannedSteps == nil && decoded.failedStep == nil)
    }
}

@Suite("Execution quality: fewer failures that are not the app's fault")
struct ExecutionQualityTests {
    private func screen(_ labels: [String]) -> Observation {
        observation(labels.enumerated().map { UIElementSnapshot(id: "e\($0.offset)", role: "staticText", label: $0.element) })
    }

    @Test("A login the app refuses is recognised from what the screen says, so the run stops with a clear reason instead of retrying")
    func loginRejection() {
        #expect(StepRecoveryPolicy.loginRejection(screen(["Log In UAT", "The username or password you entered is invalid. Please try again."])) == "The username or password you entered is invalid. Please try again.")
        #expect(StepRecoveryPolicy.loginRejection(screen(["Incorrect password"])) == "Incorrect password")
        #expect(StepRecoveryPolicy.loginRejection(screen(["Log In UAT", "Username", "Password", "Forgot Password"])) == nil, "the login form alone is not a rejection")
        #expect(StepRecoveryPolicy.loginRejection(screen(["Collection", "Invalid symbol"])) == nil, "an error about something else is not a login rejection")
        #expect(StepRecoveryPolicy.loginRejection(nil) == nil)
    }

    @Test("A text field and its clear button may share an identifier: only elements of the same role are ambiguous, so a target naming the role still grounds")
    func sharedIdentifierAcrossRoles() {
        let field = UIElementSnapshot(id: "f", role: "textField", label: "tester", identifier: "username-textfield")
        let clear = UIElementSnapshot(id: "c", role: "button", label: "close", identifier: "username-textfield")
        let twin = UIElementSnapshot(id: "t", role: "button", label: "close", identifier: "username-textfield")
        let kept = PlannerNotes.withoutSharedIdentifiers(observation([field, clear]))
        #expect(kept.elements.map(\.identifier) == ["username-textfield", "username-textfield"])
        let dropped = PlannerNotes.withoutSharedIdentifiers(observation([field, clear, twin]))
        #expect(dropped.elements.first { $0.id == "f" }?.identifier == "username-textfield")
        #expect(dropped.elements.filter { $0.role == "button" }.allSatisfy { $0.identifier == nil }, "two buttons with one identifier cannot be told apart")
    }

    @Test("An existence check passes when the label is on several rows: that is not ambiguity")
    func existsWithSeveralMatches() {
        let vocabulary = ObservedUIVocabulary.derive(from: Observation(snapshotID: "s", bundleID: "b", appState: .runningForeground, elements: [
            UIElementSnapshot(id: "a", role: "staticText", label: "MSFT"), UIElementSnapshot(id: "b", role: "staticText", label: "MSFT")]))
        let exists = TestIR(testKey: "T", title: "t", steps: [IRStep(id: "s1", sourceStepNumber: 1, intent: "check", action: .verifyOnly, verification: IRVerification(description: "d", signals: [.elementExists(SignalLocator(role: "staticText", label: "MSFT"))]))])
        #expect(ObservationGroundingService.ground(ir: exists, vocabulary: vocabulary).issues.allSatisfy { $0.status == .grounded })
        let appeared = TestIR(testKey: "T", title: "t", steps: [IRStep(id: "s1", sourceStepNumber: 1, intent: "check", action: .verifyOnly, verification: IRVerification(description: "d", signals: [.elementAppeared(SignalLocator(role: "staticText", label: "MSFT"))]))])
        #expect(ObservationGroundingService.ground(ir: appeared, vocabulary: vocabulary).issues.first?.status == .ambiguous, "an appearance check still needs one specific element")
    }
}

@Suite("Drawers the app puts over the screen")
struct InterstitialTests {
    private func screen(_ elements: [UIElementSnapshot]) -> Observation {
        Observation(snapshotID: "snap_1", bundleID: "com.apple.mobilesafari", appState: .runningForeground, elements: elements)
    }

    @Test("A named drawer close button is found; a plain Close or OK button is left alone")
    func close() {
        let drawer = screen([UIElementSnapshot(id: "e1", role: "button", label: "Close", identifier: "service-campaign-maintenance-drawer-close-button"),
                             UIElementSnapshot(id: "e2", role: "button", label: "Ok", identifier: "service-campaign-maintenance-drawer-ok-button")])
        #expect(StepRecoveryPolicy.interstitialClose(drawer)?.id == "e1")
        let plain = screen([UIElementSnapshot(id: "e3", role: "button", label: "Close"), UIElementSnapshot(id: "e4", role: "button", label: "OK", identifier: "confirm-ok")])
        #expect(StepRecoveryPolicy.interstitialClose(plain) == nil)
        #expect(StepRecoveryPolicy.interstitialClose(nil) == nil)
    }

    @Test("A close button that cannot be tapped (disabled or off screen) is not chosen")
    func notHittable() {
        let hidden = screen([UIElementSnapshot(id: "e1", role: "button", label: "Close", identifier: "x-drawer-close-button", isEnabled: false)])
        #expect(StepRecoveryPolicy.interstitialClose(hidden) == nil)
        let offscreen = screen([UIElementSnapshot(id: "e2", role: "button", label: "Close", identifier: "x-modal-close-button", isHittable: false)])
        #expect(StepRecoveryPolicy.interstitialClose(offscreen) == nil)
    }
}
