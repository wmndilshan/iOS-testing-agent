import Foundation

public enum AppState: String, Codable, Sendable {
    case runningForeground
    case runningBackground
    case notRunning
    case unknown
}

// MARK: - ObservationSource
