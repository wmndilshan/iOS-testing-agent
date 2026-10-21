import Foundation

public enum ExecutionMode: String, Codable, Sendable, CaseIterable {
    case simulation = "SIMULATION"
    case live = "LIVE"
}
