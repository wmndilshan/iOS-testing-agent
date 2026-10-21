import Foundation

public struct ProjectInfo: Codable, Sendable {
    public let projectName: String
    public let packageSwiftPresent: Bool
    public let sourceFiles: [String]
    public let projectStructure: [String]

    public func toDictionary() -> [String: AnyCodableValue] {
        return [
            "projectName": .string(projectName),
            "packageSwiftPresent": .bool(packageSwiftPresent),
            "sourceFiles": .array(sourceFiles.map { .string($0) }),
            "projectStructure": .array(projectStructure.map { .string($0) })
        ]
    }
}
