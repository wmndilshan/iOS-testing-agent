import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

public final class TestClock: ClockProtocol, @unchecked Sendable {
    private var currentDate: Date
    private let lock = NSLock()
    public private(set) var sleepCalls: [TimeInterval] = []
    public private(set) var totalSleptSeconds: TimeInterval = 0

    public init(initialDate: Date = Date()) {
        self.currentDate = initialDate
    }

    public func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return currentDate
    }

    public func advance(by seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        currentDate = currentDate.addingTimeInterval(seconds)
    }

    private func recordSleep(seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        sleepCalls.append(seconds)
        totalSleptSeconds += seconds
        currentDate = currentDate.addingTimeInterval(seconds)
    }

    public func sleep(seconds: TimeInterval) async throws {
        recordSleep(seconds: seconds)
    }

}
