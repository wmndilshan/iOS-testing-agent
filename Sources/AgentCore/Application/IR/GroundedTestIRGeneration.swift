import Foundation

/// One generation attempt's outcome, kept only for evidence and diagnostics — never
/// consulted for authorization or execution decisions.
public struct GroundedGenerationAttempt: Sendable {
    public let attemptNumber: Int
    public let decodeSucceeded: Bool
    public let validation: TestIRValidationResult?
    public let grounding: GroundingResult?
}

/// The two-stage generation's final outcome. `.blocked` is a hard stop — nothing in this
/// module ever executes tools, calls `ToolRegistry`, or touches `ScenarioExecutionController` from either
/// case; the caller decides what (if anything) to do with `.accepted`'s `TestIR`, and that caller is always
/// the same trusted pipeline (validate again if desired → semantic gate → human approval → trusted
/// execution) that already exists — this type never shortcuts it.
public enum GroundedGenerationOutcome: Sendable {
    case accepted(ir: TestIR, grounding: GroundingResult)
    case blocked(reason: String, attempts: [GroundedGenerationAttempt])
}

/// A first-attempt acceptance is a materially different claim from an acceptance that only
/// succeeded after the model was shown its own grounding failure — conflating the two would overstate how
/// often real generation needs correction. Never inferred from anything but `attemptCount`.
public enum GroundedGenerationResultKind: String, Sendable, Equatable {
    case directSuccess = "DIRECT_SUCCESS"           // grounded on attempt 1 — no feedback was ever shown to the model
    case regeneratedSuccess = "REGENERATED_SUCCESS" // grounded only after at least one grounding-failure feedback round
    case blocked = "BLOCKED"
}

/// A compact, secret-free evidence record for one grounded-generation run. Contains no
/// credentials, authorization tokens, host paths, or raw simulator internals — only IDs, statuses, and the
/// grounding issue descriptions already proven secret-free by `ObservationGroundingFeedback`/`GroundingIssue`.
public struct GroundedGenerationEvidence: Sendable, Equatable {
    public let generationID: String
    public let snapshotID: String
    public let attemptCount: Int
    public let finalStatus: String // "accepted" | "blocked"
    public let unresolvedTargetDescriptions: [String]

    /// Derived purely from `attemptCount` and `finalStatus`: attempt 1 succeeding is
    /// `.directSuccess`; attempt 2 or 3 succeeding (i.e. only after at least one regeneration) is
    /// `.regeneratedSuccess`; anything else is `.blocked`.
    public var resultKind: GroundedGenerationResultKind {
        guard finalStatus == "accepted" else { return .blocked }
        return attemptCount == 1 ? .directSuccess : .regeneratedSuccess
    }
}

/// Stage 1 (LLM + vocabulary → candidate IR) and Stage 2 (deterministic grounding against
/// the SAME authoritative vocabulary) composed into one bounded, observation-bound generation loop. The LLM
/// never gets to override Stage 2 — grounding is recomputed fresh from the real vocabulary on every attempt,
/// never trusted from the model's own claims.
///
/// This is generation correction, never execution retry: every attempt only calls
/// `TestIRGenerator.generate`/`TestIRValidator.validate`/`ObservationGroundingService.ground`, all pure or
/// network-only-to-the-LLM — nothing here ever constructs a driver, `ToolRegistry`, or
/// `ScenarioExecutionController`, and nothing here ever dispatches a device action.
public enum GroundedTestIRGeneration {
    /// At most two regeneration attempts are allowed after the initial
    /// generation, for at most 3 total LLM calls before blocking.
    public static let maxRegenerationAttempts = 2

    public static func generate(
        using generator: TestIRGenerator,
        testKey: String,
        title: String,
        stepsText: String,
        vocabulary: ObservedUIVocabulary
    ) async -> (outcome: GroundedGenerationOutcome, evidence: GroundedGenerationEvidence) {
        var attempts: [GroundedGenerationAttempt] = []
        var feedback: String? = nil
        let generationID = UUID().uuidString

        for attemptNumber in 1...(maxRegenerationAttempts + 1) {
            let ir: TestIR
            do {
                ir = try await generator.generate(testKey: testKey, title: title, stepsText: stepsText,
                                                   vocabulary: vocabulary, groundingFeedback: feedback)
            } catch {
                attempts.append(GroundedGenerationAttempt(attemptNumber: attemptNumber, decodeSucceeded: false, validation: nil, grounding: nil))
                feedback = "The previous response could not be decoded as a valid TestIR document. Output ONLY a single JSON object matching the schema, no prose."
                continue
            }

            let validation = TestIRValidator.validate(ir)
            guard validation.isAccepted else {
                attempts.append(GroundedGenerationAttempt(attemptNumber: attemptNumber, decodeSucceeded: true, validation: validation, grounding: nil))
                feedback = "The previous IR was rejected by structural validation: \(validation.rejectionReasons.joined(separator: "; "))"
                continue
            }

            let grounding = ObservationGroundingService.ground(ir: ir, vocabulary: vocabulary)
            attempts.append(GroundedGenerationAttempt(attemptNumber: attemptNumber, decodeSucceeded: true, validation: validation, grounding: grounding))

            if grounding.isFullyGrounded {
                let evidence = GroundedGenerationEvidence(generationID: generationID, snapshotID: vocabulary.snapshotID,
                                                          attemptCount: attempts.count, finalStatus: "accepted", unresolvedTargetDescriptions: [])
                return (.accepted(ir: ir, grounding: grounding), evidence)
            }
            feedback = ObservationGroundingFeedback.build(from: grounding, vocabulary: vocabulary)
        }

        let lastBlocking = attempts.last?.grounding?.blockingIssues ?? []
        let evidence = GroundedGenerationEvidence(generationID: generationID, snapshotID: vocabulary.snapshotID,
                                                  attemptCount: attempts.count, finalStatus: "blocked",
                                                  unresolvedTargetDescriptions: lastBlocking.map(\.description))
        return (.blocked(reason: "exceeded \(maxRegenerationAttempts) regeneration attempts with an unresolved/ambiguous/unsupported target",
                         attempts: attempts), evidence)
    }
}
