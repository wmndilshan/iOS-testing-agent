import Foundation

extension IRStep {
    /// Where a drag ends, as the planner wrote it in `arguments.destination` (`{role, identifier?, label?}`). The destination is data about the screen, so
    /// it is grounded against the live screen like the target, and compiled into the step's trusted locator; the proposal never supplies it.
    public var dragDestination: IRTarget? {
        guard action == .dragAndDrop, case .dictionary(let fields)? = arguments["destination"] else { return nil }
        func text(_ key: String) -> String? { if case .string(let value)? = fields[key], !value.isEmpty { value } else { nil } }
        guard text("identifier") != nil || text("label") != nil else { return nil }
        return IRTarget(role: text("role") ?? "other", identifier: text("identifier"), label: text("label"))
    }
}
