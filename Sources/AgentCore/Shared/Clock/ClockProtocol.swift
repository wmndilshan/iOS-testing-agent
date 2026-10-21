import Foundation

public protocol ClockProtocol: Sendable {
    func now() -> Date
    func sleep(seconds: TimeInterval) async throws
}

extension ClockProtocol {
    public func sleep(seconds: TimeInterval) async throws {
        if seconds > 0 {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    }
}
