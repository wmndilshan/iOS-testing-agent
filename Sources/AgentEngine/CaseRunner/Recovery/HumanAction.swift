import Foundation
import AgentCore

/// Something only a person can do while a run is going: the run holds, says what, and carries on when it is done or the time is up.
struct HumanAction: Equatable, Sendable {
    enum Kind: String, Sendable { case login, code, captcha, biometric, passcode, device, manual }
    let kind: Kind
    let title: String
    let message: String

    static let login = HumanAction(kind: .login, title: "Waiting for you to log in",
                                   message: "Log in on the simulator (type the password and tap Log In). The run continues by itself when the login screen closes.")
}

/// What on the screen, or in a step, needs a person. Kept free of the device so it can be tested.
enum HumanActionPolicy {
    private struct Rule { let kind: HumanAction.Kind; let title: String; let message: String; let screen: String?; let step: String? }

    private static let rules: [Rule] = [
        Rule(kind: .code, title: "Waiting for you to enter the verification code",
             message: "The app asks for a code (SMS, email or authenticator). Enter it on the simulator and tap its confirm button.",
             screen: #"\b(verification code|one[- ]time (password|code|passcode)|otp|security code|sms code|enter the (6|six)[- ]digit code|authenticator app)\b"#,
             step: #"\b(enter|type|provide|input|read)\b[^.]{0,40}\b(otp|verification code|one[- ]time (password|code)|sms code|2fa code|security code)\b"#),
        Rule(kind: .captcha, title: "Waiting for you to solve the captcha",
             message: "A captcha is showing. A person has to solve it on the simulator.",
             screen: #"\b(captcha|i'?m not a robot|verify (that )?you are (a )?human|select all (images|squares))\b"#,
             step: #"\b(solve|complete|pass)\b[^.]{0,30}\bcaptcha\b"#),
        Rule(kind: .device, title: "Waiting for you to approve on another device",
             message: "The sign-in must be approved on another device (a phone or a token). Approve it there.",
             screen: #"\b(approve (this )?(sign[- ]?in|login|request) on your|check your (phone|device) to approve|waiting for (your )?approval|approve on your (phone|device))\b"#,
             step: #"\bapprove\b[^.]{0,40}\bon (your|the) (phone|device|other device|authenticator)\b"#),
        Rule(kind: .passcode, title: "Waiting for you to enter the passcode",
             message: "A passcode or PIN is asked for. Enter it on the simulator.",
             screen: #"\b(enter (your )?(passcode|pin)|enter the (passcode|pin))\b"#,
             step: #"\b(enter|type)\b[^.]{0,30}\b(passcode|pin)\b(?! (field|screen))"#),
        Rule(kind: .biometric, title: "Waiting for you to confirm with Face ID or Touch ID",
             message: "In the Simulator menu choose Features > Face ID (or Touch ID) > Matching Face, or Matching Touch, to confirm.",
             screen: nil,
             step: #"\b(authenticate|confirm|unlock|approve|sign in)\b[^.]{0,30}\b(face id|touch id|biometric)"#),
        Rule(kind: .manual, title: "Waiting for you to do a manual step",
             message: "This step is marked for a person. Do it on the simulator.",
             screen: nil,
             step: #"(\[(user|manual|human)[ _-]?(action|step)?\]|\b(perform|do|complete) (this|it) manually\b|\bmanual (step|action|intervention)\b)"#)
    ]

    private static func matches(_ pattern: String, _ text: String) -> Bool { text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }

    /// What the screen asks of a person (a code, a captcha, an approval elsewhere, a passcode), unless the step is itself about that screen.
    /// A face or fingerprint prompt is not read from the screen: an app's own "Enable Face ID" notice is something a step closes by itself.
    static func detect(_ observation: Observation, stepText: String = "") -> HumanAction? {
        let text = observation.elements.flatMap { [$0.label, $0.value, $0.placeholderValue] }.compactMap { $0 }.joined(separator: " \n")
        for rule in rules {
            guard let screen = rule.screen, matches(screen, text) else { continue }
            if let step = rule.step, matches(step, stepText) { continue }
            if matches(screen, stepText) { continue }
            return HumanAction(kind: rule.kind, title: rule.title, message: rule.message)
        }
        return nil
    }

    /// A step that tells the person to do something the runner cannot (enter a code, solve a captcha, approve on a phone, confirm with Face ID).
    static func stepNeedsPerson(_ stepText: String) -> HumanAction? {
        for rule in rules {
            if let step = rule.step, matches(step, stepText) { return HumanAction(kind: rule.kind, title: rule.title, message: rule.message) }
        }
        return nil
    }
}
