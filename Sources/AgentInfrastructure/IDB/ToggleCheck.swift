import Foundation
import AgentCore

/// A tap on a switch or checkbox is only done when its value changed. idb reports a tap as sent whether or not the control reacted (a tap that lands on
/// the label next to a switch, or on a control that is disabled, changes nothing), so after a tap the control is read again and compared.
enum ToggleCheck {
    private static let toggleRoles: Set<String> = ["checkBox", "switch", "toggle", "checkbox"]
    private static let toggleValues: Set<String> = ["0", "1", "on", "off", "true", "false", "yes", "no", "checked", "unchecked"]

    static func isToggle(_ element: UIElementSnapshot) -> Bool {
        toggleRoles.contains(element.role) && toggleValues.contains((element.value ?? element.label ?? "").lowercased())
    }

    /// The same control after the tap: matched by identifier and the closest centre (several rows can share an identifier).
    static func same(as before: UIElementSnapshot, in elements: [UIElementSnapshot]) -> UIElementSnapshot? {
        guard let frame = before.frame else { return nil }
        let cx = frame.x + frame.width / 2, cy = frame.y + frame.height / 2
        return elements.filter { $0.role == before.role && $0.identifier == before.identifier }
            .compactMap { element -> (UIElementSnapshot, Double)? in
                guard let f = element.frame else { return nil }
                return (element, hypot(f.x + f.width / 2 - cx, f.y + f.height / 2 - cy))
            }
            .filter { $0.1 < 24 }.min { $0.1 < $1.1 }?.0
    }

    /// Nil when the control changed (or cannot be told); the reason when it did not.
    static func unchanged(before: UIElementSnapshot, after elements: [UIElementSnapshot]) -> String? {
        guard let now = same(as: before, in: elements), let was = before.value ?? before.label, let value = now.value ?? now.label else { return nil }
        return was.lowercased() == value.lowercased() ? "it is still “\(value)”" : nil
    }
}
