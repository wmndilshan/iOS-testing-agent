import Foundation

public struct UIElementSnapshot: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let parentID: String?
    public let role: String
    public let label: String?
    public let identifier: String?
    public let value: String?
    public let placeholderValue: String?
    public let isEnabled: Bool
    public let isHittable: Bool
    public let isSelected: Bool?
    public let hasFocus: Bool?
    public let isSecure: Bool
    public let depth: Int
    public let frame: ElementFrame?

    public init(
        id: String,
        parentID: String? = nil,
        role: String,
        label: String? = nil,
        identifier: String? = nil,
        value: String? = nil,
        placeholderValue: String? = nil,
        isEnabled: Bool = true,
        isHittable: Bool = true,
        isSelected: Bool? = nil,
        hasFocus: Bool? = nil,
        isSecure: Bool = false,
        depth: Int = 0,
        frame: ElementFrame? = nil
    ) {
        self.id = id
        self.parentID = parentID
        self.role = role
        self.label = label
        self.identifier = identifier
        self.value = value
        self.placeholderValue = placeholderValue
        self.isEnabled = isEnabled
        self.isHittable = isHittable
        self.isSelected = isSelected
        self.hasFocus = hasFocus
        self.isSecure = isSecure
        self.depth = depth
        self.frame = frame
    }

    enum CodingKeys: String, CodingKey {
        case id
        case parentID
        case role
        case label
        case identifier
        case value
        case placeholderValue
        case isEnabled
        case isHittable
        case isSelected
        case hasFocus
        case isSecure
        case depth
        case frame
        // Flat frame coordinate keys
        case frameX
        case frameY
        case frameWidth
        case frameHeight
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.parentID = try container.decodeIfPresent(String.self, forKey: .parentID)
        self.role = try container.decode(String.self, forKey: .role)
        self.label = try container.decodeIfPresent(String.self, forKey: .label)
        self.identifier = try container.decodeIfPresent(String.self, forKey: .identifier)
        self.value = try container.decodeIfPresent(String.self, forKey: .value)
        self.placeholderValue = try container.decodeIfPresent(String.self, forKey: .placeholderValue)
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        self.isHittable = try container.decodeIfPresent(Bool.self, forKey: .isHittable) ?? true
        self.isSelected = try container.decodeIfPresent(Bool.self, forKey: .isSelected)
        self.hasFocus = try container.decodeIfPresent(Bool.self, forKey: .hasFocus)
        self.isSecure = try container.decodeIfPresent(Bool.self, forKey: .isSecure) ?? false
        self.depth = try container.decodeIfPresent(Int.self, forKey: .depth) ?? 0

        // Frame resolution:
        // 1. Check nested frame first
        if let nestedFrame = try container.decodeIfPresent(ElementFrame.self, forKey: .frame) {
            self.frame = nestedFrame
        } else {
            // 2. Check flat frame fields: frameX, frameY, frameWidth, frameHeight
            let fx = try container.decodeIfPresent(Double.self, forKey: .frameX)
            let fy = try container.decodeIfPresent(Double.self, forKey: .frameY)
            let fw = try container.decodeIfPresent(Double.self, forKey: .frameWidth)
            let fh = try container.decodeIfPresent(Double.self, forKey: .frameHeight)

            // If all 4 flat fields exist, form the frame; otherwise do not invent coordinates
            if let x = fx, let y = fy, let width = fw, let height = fh {
                self.frame = ElementFrame(x: x, y: y, width: width, height: height)
            } else {
                self.frame = nil
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(parentID, forKey: .parentID)
        try container.encode(role, forKey: .role)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encodeIfPresent(identifier, forKey: .identifier)
        try container.encodeIfPresent(value, forKey: .value)
        try container.encodeIfPresent(placeholderValue, forKey: .placeholderValue)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(isHittable, forKey: .isHittable)
        try container.encodeIfPresent(isSelected, forKey: .isSelected)
        try container.encodeIfPresent(hasFocus, forKey: .hasFocus)
        try container.encode(isSecure, forKey: .isSecure)
        try container.encode(depth, forKey: .depth)
        try container.encodeIfPresent(frame, forKey: .frame)
    }
}
