import Foundation
import AgentCore
import AgentInfrastructure

@MainActor
extension Engine {
    // MARK: - Run context and exit

    struct CLIRunContext {
        let controller: ScenarioExecutionController
        let history: RunHistoryStore
        let mode: CLIExecutionMode
    }


    static func persistRun(_ ctx: CLIRunContext, failed: Bool) async {
        if failed {
            ctx.controller.finishRun(result: ctx.controller.isCancelled ? "CANCELLED" : "FAILED")
        }
        guard let trace = ctx.controller.activeRunTrace else { return }
        // Workflow-driven runs never configure the trace's run context; the CLI still knows its mode, so the record keeps it.
        let record = RunHistoryRecord.make(from: trace, humanApproved: ctx.mode.isGenuineHumanApproval, executionMode: ctx.mode.rawValue)
        do {
            try await ctx.history.save(record: record, trace: trace)
            print("✓ Run history saved: run \(trace.runID) [\(record.result)] \(trace.events.count) trace events, mode \(ctx.mode.rawValue)")
        } catch {
            print("✗ Could not save run history: \(error.localizedDescription)")
        }
    }

    /// Every CLI exit funnels through here so an aborted run still leaves a history record.
    static func terminate(_ code: Int32) async -> Never {
        if let ctx = runContext { await persistRun(ctx, failed: code != 0) }
        exit(code)
    }
}
