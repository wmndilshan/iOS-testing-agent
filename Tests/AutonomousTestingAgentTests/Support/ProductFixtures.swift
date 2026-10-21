import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

enum ProductFixtures {
    static let bundleID = "com.apple.mobilesafari"

    static func element(_ id: String, role: String = "button", identifier: String? = nil, label: String? = nil,
                        enabled: Bool = true, hittable: Bool = true) -> UIElementSnapshot {
        UIElementSnapshot(id: id, role: role, label: label, identifier: identifier, isEnabled: enabled, isHittable: hittable,
                          frame: ElementFrame(x: 10, y: 10, width: 100, height: 40))
    }

    static func observation(_ tag: String, _ elements: [UIElementSnapshot], targetBundleID: String = bundleID) -> Observation {
        Observation(snapshotID: "snap_\(tag)_\(UUID().uuidString.prefix(6))", bundleID: targetBundleID, appState: .runningForeground, elements: elements)
    }

    static let dropdown = element("elem_29", identifier: "change-language-dropdown-button", label: "English")
    static let closeButton = element("elem_33", identifier: "close_var_1", label: "close_var_1")

    static func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("prod-\(UUID().uuidString)")
    }
}
