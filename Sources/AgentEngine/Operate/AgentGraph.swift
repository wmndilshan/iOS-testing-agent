import Foundation

/// One step of a graph: an agent that does a piece of work, or a function that does a fixed one (reading the screen, choosing the next goal).
/// Nodes read and write the shared `OperatorBoard`; they do not call each other.
struct GraphNode: Sendable {
    enum Kind: String, Sendable { case agent, function, router }

    let name: String
    let kind: Kind
    let run: @Sendable (OperatorBoard) async throws -> Void
}

/// Where the run goes after a node: always to one node, to one of several chosen by code from the board (no model call), or to the end.
enum GraphEdge: Sendable {
    case next(String)
    case branch(@Sendable (OperatorBoard) async -> String)
    case end
}

/// A small state graph, in the manner of LangGraph: named nodes, edges (some conditional), a shared state, an entry and an end. The routing is code,
/// so choosing the next step costs no model call; the models are used inside the nodes that need judgement.
struct AgentGraph: Sendable {
    static let end = "END"

    enum Outcome: String, Sendable { case finished, stopped, stepLimit }
    enum Invalid: Error, Equatable { case missingNode(String), missingEdge(String), unknownEntry(String) }

    let nodes: [String: GraphNode]
    let edges: [String: GraphEdge]
    let entry: String
    let maxSteps: Int

    /// Every node has an edge, every edge points at a node (or the end), and the entry exists.
    func validate() throws {
        guard nodes[entry] != nil else { throw Invalid.unknownEntry(entry) }
        for name in nodes.keys where edges[name] == nil { throw Invalid.missingEdge(name) }
        for (name, edge) in edges {
            guard nodes[name] != nil else { throw Invalid.missingNode(name) }
            if case .next(let target) = edge, target != Self.end, nodes[target] == nil { throw Invalid.missingNode(target) }
        }
    }

    func run(board: OperatorBoard, reporter: AgentReporter, gate: PauseGate) async throws -> Outcome {
        try validate()
        var current = entry
        var steps = 0
        while current != Self.end {
            await gate.checkpoint()
            if await gate.isStopped { return .stopped }
            if await gate.takeResumed() { await board.markScreenStale() }
            guard steps < maxSteps else { return .stepLimit }
            steps += 1
            guard let node = nodes[current], let edge = edges[current] else { throw Invalid.missingNode(current) }
            let goal = await board.currentGoal?.number ?? 0
            reporter.send(["t": "graph-node", "name": current, "kind": node.kind.rawValue, "state": "enter", "step": steps, "goal": goal])
            let started = Date()
            do { try await node.run(board) }
            catch Agent.Failure.stopped { return .stopped }
            reporter.send(["t": "graph-node", "name": current, "kind": node.kind.rawValue, "state": "exit", "step": steps, "goal": goal, "ms": Int(Date().timeIntervalSince(started) * 1000)])
            let next: String
            switch edge {
            case .next(let target): next = target
            case .branch(let choose): next = await choose(board)
            case .end: next = Self.end
            }
            reporter.send(["t": "graph-edge", "from": current, "to": next])
            current = next
        }
        return .finished
    }
}
