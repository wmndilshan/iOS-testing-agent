import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// Deterministic clock feeding `BudgetedLLMClient`'s latency measurement.
final class TickClock: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimeInterval]
    init(_ values: [TimeInterval]) { self.values = values }
    func next() -> Date {
        lock.withLock { Date(timeIntervalSince1970: values.isEmpty ? 0 : values.removeFirst()) }
    }
}

