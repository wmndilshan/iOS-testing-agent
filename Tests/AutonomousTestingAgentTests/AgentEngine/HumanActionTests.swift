import Testing
import Foundation
@testable import AgentCore
@testable import AgentEngine

@Suite("Things only a person can do")
struct HumanActionTests {
    private func screen(_ labels: String...) -> Observation {
        Observation(snapshotID: "s", timestamp: Date(), bundleID: "com.apple.mobilesafari", appState: .runningForeground, source: .accessibilityTree,
                    elements: labels.enumerated().map { UIElementSnapshot(id: "e\($0.offset)", role: "staticText", label: $0.element) })
    }

    @Test("A screen that asks for a code, a captcha, an approval elsewhere or a passcode needs a person")
    func screens() {
        #expect(HumanActionPolicy.detect(screen("Enter the 6-digit code we sent you"))?.kind == .code)
        #expect(HumanActionPolicy.detect(screen("Enter your OTP"))?.kind == .code)
        #expect(HumanActionPolicy.detect(screen("Please verify you are human"))?.kind == .captcha)
        #expect(HumanActionPolicy.detect(screen("Check your phone to approve"))?.kind == .device)
        #expect(HumanActionPolicy.detect(screen("Enter your passcode"))?.kind == .passcode)
        #expect(HumanActionPolicy.detect(screen("Collection", "My Collection", "Add Symbols")) == nil)
        #expect(HumanActionPolicy.detect(screen("hotpot", "optional notes")) == nil)
    }

    @Test("A screen is not a person's job when the step is itself about that screen; an app's Face ID notice is left to the steps")
    func exclusions() {
        #expect(HumanActionPolicy.detect(screen("Enter the 6-digit code we sent you"), stepText: "Verify the verification code screen is displayed") == nil)
        #expect(HumanActionPolicy.detect(screen("Enable Face ID for faster login")) == nil)
    }

    @Test("A step that tells a person to act is theirs; a step that only checks is not")
    func steps() {
        #expect(HumanActionPolicy.stepNeedsPerson("Enter the OTP code received by SMS")?.kind == .code)
        #expect(HumanActionPolicy.stepNeedsPerson("Solve the captcha")?.kind == .captcha)
        #expect(HumanActionPolicy.stepNeedsPerson("Approve the sign-in on your phone")?.kind == .device)
        #expect(HumanActionPolicy.stepNeedsPerson("Authenticate with Face ID")?.kind == .biometric)
        #expect(HumanActionPolicy.stepNeedsPerson("[MANUAL] Insert the card")?.kind == .manual)
        #expect(HumanActionPolicy.stepNeedsPerson("Verify the OTP screen is displayed") == nil)
        #expect(HumanActionPolicy.stepNeedsPerson("Tap the Collection button") == nil)
    }

    @Test("Recovery reports the person's action after the login check")
    func recovery() {
        #expect(StepRecoveryPolicy.assess(screen("Enter the verification code"), isLoginStep: false) == .needsPerson(HumanActionPolicy.detect(screen("Enter the verification code"))!))
        #expect(StepRecoveryPolicy.assess(screen("Enter the verification code"), isLoginStep: false, stepText: "Check the verification code field") == .none)
    }
}
