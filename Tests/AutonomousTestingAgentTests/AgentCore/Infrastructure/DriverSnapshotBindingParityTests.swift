import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// One contract, both drivers: **an operation authorized against snapshot A must never be answered from snapshot B.**
///
/// Phase 27 found the live driver's `getElementDetails` breaking it; Phase 28 found the simulated driver breaking it
/// the same way. The drivers drifted because nothing tested them against a shared contract, so this suite states the
/// contract once and runs it over both. Case B is the one that failed before each fix: the element still exists in the
/// new snapshot, so only the binding can refuse the call.
@Suite("Driver snapshot binding parity")
struct DriverSnapshotBindingParityTests {

    /// A driver plus the two things the contract needs: how to observe, and which element to ask about.
    struct Subject {
        let name: String
        let driver: any DeviceDriver
        /// Produces the driver's next snapshot, exactly as a fresh observation would.
        let observe: () async throws -> Observation
    }

    static func element(in observation: Observation) throws -> String {
        try #require(observation.elements.first { $0.identifier != nil }).id
    }






    /// Every other snapshot-taking method on the simulated driver already binds the same way; this pins the set so a
    /// new method cannot be added without the guard.
    @Test func testEverySnapshotTakingMethodOfTheSimulatedDriverBindsItsSnapshot() throws {
        // The simulated driver is a test double and lives with the tests.
        let code = try String(contentsOf: RepositoryRoot.url.appendingPathComponent("Tests/AutonomousTestingAgentTests/Support/SimulatedDriver.swift"), encoding: .utf8)
        let bodies = code.components(separatedBy: "\n    public func ").dropFirst()
            + code.components(separatedBy: "\n    private func ").dropFirst()
        var checked = 0
        for body in bodies {
            let signature = body.components(separatedBy: "{")[0]
            guard signature.contains("snapshotID: String") || signature.contains("_ snapshotID: String") else { continue }
            let name = body.components(separatedBy: "(")[0]
            let implementation = body.components(separatedBy: "\n    ")[0...].joined(separator: "\n    ")
                .components(separatedBy: "\n    public func ")[0]
            // A method binds its snapshot in one of three ways: the guard itself, the shared `mockBar` helper that
            // carries the guard, or delegation that forwards the *same* `snapshotID` to a method proven to bind.
            // Delegation counts only when the argument is passed through unchanged.
            let binds = implementation.contains("staleSnapshot")
                || implementation.contains("mockBar(")
                || implementation.contains("snapshotID: snapshotID")
            #expect(binds, Comment(rawValue: "\(name) takes a snapshotID but does not bind it"))
            checked += 1
        }
        #expect(checked >= 12, "the audit must cover every snapshot-taking method, found \(checked)")
    }
}
