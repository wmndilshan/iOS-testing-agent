import Foundation
import AgentCore

extension CaseRunSession {
    /// How long a run waits for a person (a login on the simulator, a code, an answer to a question) before it stops: `ATA_USER_WAIT_SECONDS`, ten minutes by default.
    static var personWaitSeconds: TimeInterval {
        ProcessInfo.processInfo.environment["ATA_USER_WAIT_SECONDS"].flatMap(TimeInterval.init).map { max(5, $0) } ?? 600
    }

    /// The run needs a person to log in on the simulator.
    func waitForHumanLogin() async {
        await waitForPerson(.login) { !StepRecoveryPolicy.isLoginScreen($0) }
    }

    /// The run needs a person to do something on the simulator (log in, enter a code, solve a captcha, approve elsewhere, confirm with Face ID).
    /// It says so (the command line prints the time left; the app and the tools show a banner or a notification), then waits until `finished` says
    /// the screen has moved on, or the person says "done" (the app's Done button, or typing `done` at the terminal). When nobody does it in time the
    /// run stops with a reason, instead of failing the steps after it for a reason that is not theirs.
    /// With no `finished` check (a step the screen cannot show the end of) the screen changing is taken as the person having acted.
    func waitForPerson(_ action: HumanAction, finished: ((Observation) -> Bool)? = nil) async {
        guard mode.isLive else {
            print("HUMAN STEP (simulated run): \(action.title.lowercased()) would happen here.")
            return
        }
        let limit = Self.personWaitSeconds
        let id = action.kind.rawValue
        print("\n>>> WAITING FOR YOU: \(action.message) Type done and press Return when it is done. Timeout \(Int(limit)) s.")
        Engine.emit(["t": "waiting", "id": id, "kind": "wait-\(id)", "title": action.title, "message": action.message, "timeout": Int(limit)])
        Engine.activity(step: 0, kind: "wait", "\(action.title) (\(Int(limit)) s)")
        let start = Date()
        var lastPrinted = start
        var result = "timeout"
        let baseline = (try? await driver.captureObservation(bundleID: bundleID)).map(Self.screenFingerprint)
        while Date().timeIntervalSince(start) < limit, !aborted {
            let polled = Date()
            if let observation = try? await driver.captureObservation(bundleID: bundleID) {
                if let finished { if finished(observation) { result = "done"; break } }
                else if let baseline, Self.screenFingerprint(observation) != baseline { result = "done"; break }
            }
            if Date().timeIntervalSince(lastPrinted) >= 30 {
                lastPrinted = Date()
                print(">>> Still waiting for you: \(Int(limit - Date().timeIntervalSince(start))) s left.")
            }
            // The wait between looks is also where "done" is heard.
            if let said = StdinAnswers.shared.next(timeout: 2)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), ["done", "ok", "continue"].contains(said) { result = "done"; break }
            if Date().timeIntervalSince(polled) < 0.5 { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        }
        Engine.emit(["t": "waiting-done", "id": id, "result": result])
        if result == "done" {
            print(">>> Thank you. Resuming autonomous execution in 5 seconds.")
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        } else if !aborted {
            print(">>> Timed out after \(Int(limit)) s waiting for you. Stopping the run.")
            block("\(action.title.replacingOccurrences(of: "Waiting for you to ", with: "Nobody ").replacingOccurrences(of: "Waiting for you", with: "Nobody acted")) within \(Int(limit)) seconds, so the run stopped. Do it on the simulator and run again (or resume from this step).")
        }
    }

    /// Which controls are on the screen (not what is typed into them, so entering a code is not taken for the end of the wait).
    static func screenFingerprint(_ observation: Observation) -> Int {
        var hasher = Hasher()
        for element in observation.elements { hasher.combine(element.role); hasher.combine(element.label) }
        return hasher.finalize()
    }
}
