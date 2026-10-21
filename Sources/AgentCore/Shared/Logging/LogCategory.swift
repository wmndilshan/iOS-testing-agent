import Foundation

/// The closed set of log categories. Files do not invent category strings.
public enum LogCategory: String, Sendable, Codable, CaseIterable {
    case application, lifecycle, configuration
    case llm
    case llmNetwork = "llm.network"
    case proposal, validation, approval, authorization
    case execution, tool, xctest, simulator
    case observation, verification, recovery
    case skills, persistence, inspector, integration
    case security, performance
}
