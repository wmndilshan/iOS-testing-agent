import Testing
import Foundation
@testable import AgentCore
@testable import AgentEngine

@Suite("Login screen detection")
struct LoginScreenTests {
    private func observation(_ elements: [UIElementSnapshot]) -> Observation {
        Observation(snapshotID: "s", timestamp: Date(), bundleID: "com.apple.mobilesafari", appState: .runningForeground, source: .accessibilityTree, elements: elements)
    }

    @Test("A password field that the tree shows as a button, beside a login button, is a login screen")
    func buttonPasswordField() {
        let screen = observation([
            UIElementSnapshot(id: "1", role: "textField", label: "Username", identifier: "username-textfield"),
            UIElementSnapshot(id: "2", role: "button", label: "remove_red_eye", identifier: "password-textfield"),
            UIElementSnapshot(id: "3", role: "button", label: "Log In", identifier: "login-button")
        ])
        #expect(StepRecoveryPolicy.isLoginScreen(screen))
        #expect(StepRecoveryPolicy.assess(screen, isLoginStep: false) == .loggedOut)
        #expect(StepRecoveryPolicy.assess(screen, isLoginStep: true) == .none)
    }

    @Test("A secure text field is one; a screen with no password field or no login button is not")
    func others() {
        #expect(StepRecoveryPolicy.isLoginScreen(observation([UIElementSnapshot(id: "1", role: "secureTextField", label: "Password")])))
        #expect(!StepRecoveryPolicy.isLoginScreen(observation([UIElementSnapshot(id: "1", role: "button", label: "Log In", identifier: "login-button")])))
        #expect(!StepRecoveryPolicy.isLoginScreen(observation([UIElementSnapshot(id: "1", role: "button", label: "Collection", identifier: "tab-collection")])))
    }
}
