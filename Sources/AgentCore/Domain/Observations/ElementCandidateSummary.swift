import Foundation

public struct ElementCandidateSummary: Codable, Sendable, Equatable {
    public let elementID: String
    public let role: String
    public let identifier: String?
    public let label: String?
    public let frame: ElementFrame?

    public init(
        elementID: String,
        role: String,
        identifier: String? = nil,
        label: String? = nil,
        frame: ElementFrame? = nil
    ) {
        self.elementID = elementID
        self.role = role
        self.identifier = identifier
        self.label = label
        self.frame = frame
    }
}
