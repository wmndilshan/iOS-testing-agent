import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure

@Suite("idb accessibility tree")
struct IDBAccessibilityTreeTests {
    private func element(_ json: String) -> UIElementSnapshot {
        let node = (try! JSONSerialization.jsonObject(with: Data(json.utf8))) as! [String: Any]
        return IDBAccessibilityTree.element(from: node, index: 1, window: ElementFrame(x: 0, y: 0, width: 402, height: 874))
    }

    @Test("The default backend's `enabled` is used as it is")
    func enabledField() {
        #expect(element(#"{"type":"Button","enabled":false,"frame":{"x":10,"y":10,"width":50,"height":40}}"#).isEnabled == false)
        #expect(element(#"{"type":"Button","enabled":true,"frame":{"x":10,"y":10,"width":50,"height":40}}"#).isEnabled)
    }

    @Test("The axbridge backend leaves `enabled` null and marks a disabled control with the NotEnabled trait")
    func notEnabledTrait() {
        let disabled = element(#"{"type":"Button","enabled":null,"traits":["NotEnabled","Button"],"frame":{"x":10,"y":10,"width":50,"height":40}}"#)
        #expect(!disabled.isEnabled && !disabled.isHittable, "a disabled control is neither enabled nor tappable")
        #expect(element(#"{"type":"Button","enabled":null,"traits":["Button"],"frame":{"x":10,"y":10,"width":50,"height":40}}"#).isEnabled)
        #expect(element(#"{"type":"Button","frame":{"x":10,"y":10,"width":50,"height":40}}"#).isEnabled, "nothing says it is disabled")
    }
}
