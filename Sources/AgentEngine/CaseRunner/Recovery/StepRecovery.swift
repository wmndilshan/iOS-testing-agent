import Foundation
import AgentCore
import AgentInfrastructure

/// Gets the app back to a state a step can run in: in front, and logged in. It runs before a failed step is retried and before a resumed run
/// starts in the middle of a case. It acts only on what it can see (the app is unreachable, the login screen is showing) and does each thing at
/// most once, so a recovery cannot loop.
@MainActor
struct StepRecovery {
    let session: CaseRunSession
    let loginSteps: [CaseStep]
    /// Runs one case step through the normal planner, judge and skills.
    let runStep: (CaseStep) async -> Void

    func prepare(for step: CaseStep) async {
        let isLogin = loginSteps.contains { $0.number == step.number }
        var observation = await session.observe()
        if StepRecoveryPolicy.assess(observation, isLoginStep: isLogin) == .appNotReachable {
            say(step, "The app is not reachable. Bringing \(session.bundleID) to the front.")
            if let launcher = session.driver as? any AppForegrounding {
                await launcher.bringToForeground(bundleID: session.bundleID)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
            observation = await session.observe()
        }
        let need = StepRecoveryPolicy.assess(observation, isLoginStep: isLogin, stepText: step.text)
        if need == .loggedOut { await logIn(again: step) }
        else if case .needsPerson(let action) = need {
            say(step, "\(action.title): the screen needs a person before step \(step.number).")
            await session.waitForPerson(action) { observed in HumanActionPolicy.detect(observed, stepText: step.text) == nil }
        }
        else if let close = StepRecoveryPolicy.interstitialClose(observation), let observed = observation, !stepIsAbout(step, close) {
            // The app put a notice over the screen (a maintenance or campaign drawer): close it, as a person would, and look again.
            say(step, "A drawer is covering the screen (\(close.identifier ?? "close")): closing it before step \(step.number).")
            _ = try? await session.driver.tap(snapshotID: observed.snapshotID, elementID: close.id)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    /// A step that is itself about closing that drawer must not have it closed first.
    private func stepIsAbout(_ step: CaseStep, _ close: UIElementSnapshot) -> Bool {
        let text = step.text.lowercased()
        return text.contains("drawer") || text.contains("popup") || text.contains("modal") || text.contains("campaign") || text.contains("maintenance")
    }

    /// The session expired: the case's own login steps are run again. The password is asked for only when this process does not hold it
    /// (a resumed run is a new process), and without a prompt (`--events` off) the person types it in the simulator.
    private func logIn(again step: CaseStep) async {
        say(step, "The login screen is showing: the session expired. Logging in again before step \(step.number).")
        guard session.mode.isLive, !loginSteps.isEmpty else { await session.waitForHumanLogin(); return }
        if (session.credentials["TEST_USER_PASSWORD"] ?? "").isEmpty {
            guard Engine.emitsEvents,
                  let password = Engine.ask(id: "password", kind: "password", title: "Password",
                                                            message: "The session expired. Enter the password to log in again; it is typed into the app and never stored.", secure: true),
                  !password.isEmpty else { await session.waitForHumanLogin(); return }
            session.setCredential("TEST_USER_PASSWORD", password)
        }
        for loginStep in loginSteps where !session.aborted {
            print("--- re-login, step \(loginStep.number): \(loginStep.text)")
            await runStep(loginStep)
        }
    }

    private func say(_ step: CaseStep, _ text: String) {
        print("  \(text)")
        Engine.emit(["t": "think", "step": step.number, "phase": "recovery", "text": text])
    }
}

extension CaseRunSession {
    /// A run begins with its app in front, as a person would tap its icon first. Another app on top (the last run's, the home screen) is not
    /// a failure of the case. A running app keeps its state: it is brought forward, never restarted.
    func ensureAppInFront() async {
        do {
            _ = try await driver.captureObservation(bundleID: bundleID)
        } catch DriverError.wrongApplication(_, let observed, let verdict) where verdict == .notForeground {
            guard let launcher = driver as? any AppForegrounding else { return }
            print("  \(observed) is in front; bringing \(bundleID) to the front.")
            await launcher.bringToForeground(bundleID: bundleID)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        } catch {
            // Anything else is reported by the first real observation, with its retries.
        }
    }
}
