import Foundation

public enum ToolStatus: String, Codable, Sendable, Equatable {
    case success
    case failed
    case timedOut
    case rejected
}

/// Why a tool did not succeed, in neutral terms.
public struct ToolFailure: Codable, Sendable, Equatable {
    public let category: ErrorCategory
    /// True only when repeating the same read-only request could succeed. Never true for a device action.
    public let retryable: Bool
    public let message: String

    public init(category: ErrorCategory, retryable: Bool = false, message: String) {
        self.category = category
        self.retryable = retryable
        self.message = message
    }
}

public struct ToolResult: Codable, Sendable, Equatable {
    public let callID: String
    public let status: ToolStatus
    public let summary: String
    public let observation: Observation?
    public let payload: [String: AnyCodableValue]?
    /// The tool that produced this result, its execution correlation ID and how long it took.
    public var toolName: String?
    public var executionID: String?
    public var durationSeconds: Double?
    /// Set when `status` is not `.success`.
    public var failure: ToolFailure?
    /// Large outputs (screenshots, exports, reports) are stored as artifacts and referenced here,
    /// never embedded in the result.
    public var artifacts: [ArtifactReference]

    public init(
        callID: String,
        status: ToolStatus,
        summary: String,
        observation: Observation? = nil,
        payload: [String: AnyCodableValue]? = nil,
        toolName: String? = nil,
        executionID: String? = nil,
        durationSeconds: Double? = nil,
        failure: ToolFailure? = nil,
        artifacts: [ArtifactReference] = []
    ) {
        self.callID = callID
        self.status = status
        self.summary = summary
        self.observation = observation
        self.payload = payload
        self.toolName = toolName
        self.executionID = executionID
        self.durationSeconds = durationSeconds
        self.failure = failure
        self.artifacts = artifacts
    }

    private enum CodingKeys: String, CodingKey {
        case callID, status, summary, observation, payload, toolName, executionID, durationSeconds, failure, artifacts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        callID = try c.decode(String.self, forKey: .callID)
        status = try c.decode(ToolStatus.self, forKey: .status)
        summary = try c.decode(String.self, forKey: .summary)
        observation = try c.decodeIfPresent(Observation.self, forKey: .observation)
        payload = try c.decodeIfPresent([String: AnyCodableValue].self, forKey: .payload)
        toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
        executionID = try c.decodeIfPresent(String.self, forKey: .executionID)
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds)
        failure = try c.decodeIfPresent(ToolFailure.self, forKey: .failure)
        artifacts = try c.decodeIfPresent([ArtifactReference].self, forKey: .artifacts) ?? []
    }

    public func toDictionary() -> [String: AnyCodableValue] {
        var map: [String: AnyCodableValue] = [
            "callID": .string(callID),
            "status": .string(status.rawValue),
            "summary": .string(summary)
        ]
        if let obs = observation {
            map["snapshotID"] = .string(obs.snapshotID)
            map["elementCount"] = .int(obs.elements.count)
        }
        if let p = payload {
            for (k, v) in p {
                map[k] = v
            }
        }
        return map
    }
}
