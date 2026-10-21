import Foundation
import AgentCore
import AgentInfrastructure

/// What a run must put right before a failed step is tried again (or before a resumed run starts in the middle of a case).
enum RecoveryNeed: Equatable {
    case none
    /// The app cannot be observed: it crashed, or another app is in front. It is brought to the front (never restarted if it is running).
    case appNotReachable
    /// The login screen is showing in the middle of a case: the session expired.
    case loggedOut
    /// The screen asks for something only a person can do (a verification code, a captcha, an approval on another device, a passcode).
    case needsPerson(HumanAction)
}

/// The decisions, kept free of the device so they can be tested: what the screen says about the run, and which steps log in.
enum StepRecoveryPolicy {
    private static let expiredPhrases = ["session has expired", "session expired", "please log in again", "please login again", "you have been logged out"]

    /// The login screen: a password field (a secure text field, or what the accessibility tree calls a control named for the password, as this app's
    /// show/hide eye button) beside a login button. A password field alone is not enough: a settings screen can have one.
    static func isLoginScreen(_ observation: Observation) -> Bool {
        if observation.elements.contains(where: { $0.role == "secureTextField" }) { return true }
        func text(_ element: UIElementSnapshot) -> String { [element.identifier, element.label].compactMap { $0?.lowercased() }.joined(separator: " ") }
        let hasPassword = observation.elements.contains { text($0).contains("password-textfield") || text($0).contains("password-field") }
        let hasLogin = observation.elements.contains { element in
            element.role == "button" && ["login-button", "log in", "sign in", "signin-button", "sign-in-button"].contains { text(element).contains($0) }
        }
        return hasPassword && hasLogin
    }

    static func assess(_ observation: Observation?, isLoginStep: Bool, stepText: String = "") -> RecoveryNeed {
        guard let observation else { return .appNotReachable }
        guard !isLoginStep else { return .none }
        let hasPasswordField = isLoginScreen(observation)
        let sayExpired = observation.elements.contains { element in
            let text = [element.label, element.value].compactMap { $0?.lowercased() }.joined(separator: " ")
            return expiredPhrases.contains { text.contains($0) }
        }
        if hasPasswordField || sayExpired { return .loggedOut }
        return HumanActionPolicy.detect(observation, stepText: stepText).map { .needsPerson($0) } ?? .none
    }

    /// A drawer, popup or modal the app put over the screen on its own (a maintenance notice, a campaign, a "what's new"): the control that closes it,
    /// found by its identifier (`…-drawer-close-button`, `…-modal-close-button`, `…-popup-close-button`). Only these named close buttons count; a
    /// button labelled "Close" or "OK" elsewhere may be part of what a step is testing, so it is never tapped on the app's behalf.
    static func interstitialClose(_ observation: Observation?) -> UIElementSnapshot? {
        guard let observation else { return nil }
        return observation.elements.first { element in
            guard element.isHittable, element.isEnabled, let identifier = element.identifier?.lowercased() else { return false }
            return ["-drawer-close-button", "-modal-close-button", "-popup-close-button", "-sheet-close-button"].contains { identifier.hasSuffix($0) }
        }
    }

    /// "The username or password you entered is invalid": the app answered a login and refused it. Trying the step again (or logging in again with the
    /// same details) cannot help, so the run stops and says what to fix. The message the app showed, or nil when nothing on screen rejects a login.
    static func loginRejection(_ observation: Observation?) -> String? {
        guard let observation else { return nil }
        for element in observation.elements {
            for text in [element.label, element.value].compactMap({ $0 }) {
                let lowered = text.lowercased()
                let refuses = ["invalid", "incorrect", "wrong", "does not match", "not recognized", "not recognised", "failed"].contains { lowered.contains($0) }
                let aboutLogin = ["password", "username", "credentials", "login", "log in", "sign in", "email"].contains { lowered.contains($0) }
                if refuses, aboutLogin, text.count <= 160 { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
        }
        return nil
    }

    /// The steps that log in, in order: from the first that names the username (or the password) up to the step after the password step.
    /// Empty when the case has no password step, so there is nothing the runner can repeat on its own.
    static func loginSteps(in steps: [CaseStep]) -> [CaseStep] {
        guard let password = steps.lastIndex(where: { $0.text.contains("[CREDENTIALS]") }) else { return [] }
        let start = steps.firstIndex { $0.text.lowercased().contains("username") || $0.text.contains("[CREDENTIALS]") } ?? password
        let end = min(password + 1, steps.count - 1)
        return Array(steps[min(start, password)...end])
    }
}
