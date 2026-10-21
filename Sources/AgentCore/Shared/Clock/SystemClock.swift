import Foundation

public struct SystemClock: ClockProtocol {
    public init() {}
    public func now() -> Date {
        Date()
    }
}
