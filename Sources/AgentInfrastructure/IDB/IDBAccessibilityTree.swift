import Foundation
import AgentCore

/// idb's accessibility tree (`ui describe-all`) as elements. One reading of the tree, shared by the case runner's driver and the device-control
/// lane, so both see the same screen.
enum IDBAccessibilityTree {
    /// The tree's nodes, or nil when the output is not a JSON array.
    static func nodes(from data: Data) -> [[String: Any]]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    }

    // MARK: - Mapping

    static func frame(of node: [String: Any]) -> ElementFrame? {
        guard let f = node["frame"] as? [String: Any],
              let x = (f["x"] as? NSNumber)?.doubleValue, let y = (f["y"] as? NSNumber)?.doubleValue,
              let w = (f["width"] as? NSNumber)?.doubleValue, let h = (f["height"] as? NSNumber)?.doubleValue else { return nil }
        return ElementFrame(x: x, y: y, width: w, height: h)
    }

    static func element(from node: [String: Any], index: Int, window: ElementFrame?) -> UIElementSnapshot {
        let type = node["type"] as? String ?? "Other"
        let subrole = node["subrole"] as? String ?? ""
        let secure = type.contains("Secure") || subrole.contains("Secure")
        let role: String
        switch type {
        case "Application": role = "application"
        case "Group": role = "other"
        case _ where secure: role = "secureTextField"
        default: role = type.prefix(1).lowercased() + type.dropFirst()
        }
        let frame = frame(of: node)
        // The default backend says `enabled`; the `axbridge` backend leaves it null and lists a "NotEnabled" trait instead. Without this a disabled control
        // read through the bridge looks enabled, and a check that something is disabled can never pass.
        let enabled = node["enabled"] as? Bool ?? !((node["traits"] as? [String])?.contains("NotEnabled") ?? false)
        var hittable = enabled && (frame.map { $0.width > 0 && $0.height > 0 } ?? false)
        if hittable, let frame, let window {
            let cx = frame.x + frame.width / 2, cy = frame.y + frame.height / 2
            hittable = cx >= window.x && cx <= window.x + window.width && cy >= window.y && cy <= window.y + window.height
        }
        func text(_ key: String) -> String? { (node[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        return UIElementSnapshot(id: "elem_\(index + 1)", role: role, label: text("AXLabel"), identifier: text("AXUniqueId"), value: text("AXValue"),
                                 isEnabled: enabled, isHittable: hittable, isSecure: secure, depth: index == 0 ? 0 : 1, frame: frame)
    }
}
