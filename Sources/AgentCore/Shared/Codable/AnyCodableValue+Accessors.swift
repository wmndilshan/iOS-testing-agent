import Foundation

extension AnyCodableValue {
    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

}
