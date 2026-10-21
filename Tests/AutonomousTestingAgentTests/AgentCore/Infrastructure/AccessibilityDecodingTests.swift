import Foundation
import Testing
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("Accessibility attachment decoding")
struct AccessibilityDecodingTests {
    @Test func testFlatFrameFieldsDecodeToElementFrame() throws {
        let json = """
        {
            "id": "elem_button",
            "role": "button",
            "identifier": "login-button",
            "label": "Log In",
            "frameX": 18.666666666666664,
            "frameY": 438.6666666666667,
            "frameWidth": 364.66666666666663,
            "frameHeight": 41.33333333333326,
            "isEnabled": true,
            "isHittable": true,
            "isSecure": false,
            "depth": 1
        }
        """
        let data = try #require(json.data(using: .utf8))
        let decoded = try JSONDecoder().decode(UIElementSnapshot.self, from: data)

        #expect(decoded.id == "elem_button")
        #expect(decoded.role == "button")
        #expect(decoded.identifier == "login-button")
        #expect(decoded.label == "Log In")
        #expect(decoded.frame != nil)
        #expect(decoded.frame?.x == 18.666666666666664)
        #expect(decoded.frame?.y == 438.6666666666667)
        #expect(decoded.frame?.width == 364.66666666666663)
        #expect(decoded.frame?.height == 41.33333333333326)
    }

    @Test func testExistingNestedFrameJSONStillDecodes() throws {
        let json = """
        {
            "id": "elem_legacy",
            "role": "staticText",
            "label": "Welcome",
            "frame": {
                "x": 24.0,
                "y": 100.0,
                "width": 200.0,
                "height": 44.0
            },
            "isEnabled": true,
            "isHittable": true,
            "isSecure": false,
            "depth": 1
        }
        """
        let data = try #require(json.data(using: .utf8))
        let decoded = try JSONDecoder().decode(UIElementSnapshot.self, from: data)

        #expect(decoded.id == "elem_legacy")
        #expect(decoded.frame != nil)
        #expect(decoded.frame?.x == 24.0)
        #expect(decoded.frame?.y == 100.0)
        #expect(decoded.frame?.width == 200.0)
        #expect(decoded.frame?.height == 44.0)
    }

    @Test func testMissingOrIncompleteFrameFieldsDoNotFabricateCoordinates() throws {
        // 1. Missing all frame fields
        let jsonNoFrame = """
        {
            "id": "elem_no_frame",
            "role": "other",
            "isEnabled": true,
            "isHittable": false,
            "isSecure": false,
            "depth": 0
        }
        """
        let dataNoFrame = try #require(jsonNoFrame.data(using: .utf8))
        let decodedNoFrame = try JSONDecoder().decode(UIElementSnapshot.self, from: dataNoFrame)
        #expect(decodedNoFrame.frame == nil)

        // 2. Incomplete flat fields (only frameX and frameY present, width/height missing)
        let jsonIncomplete = """
        {
            "id": "elem_partial",
            "role": "button",
            "frameX": 10.0,
            "frameY": 20.0,
            "isEnabled": true,
            "isHittable": true,
            "isSecure": false,
            "depth": 1
        }
        """
        let dataIncomplete = try #require(jsonIncomplete.data(using: .utf8))
        let decodedIncomplete = try JSONDecoder().decode(UIElementSnapshot.self, from: dataIncomplete)
        #expect(decodedIncomplete.frame == nil)
    }

    @Test func testRealExportedAttachmentDecodesWithFramesAndDisambiguation() throws {
        let config = try Configuration.load()
        let exportedURL = config.projectRoot.appendingPathComponent(".build")
            .appendingPathComponent("xcresults")
            .appendingPathComponent("exported_attachments")
            .appendingPathComponent("CD22CBF1-6895-4A94-96FD-E56257BA952C.json")

        guard FileManager.default.fileExists(atPath: exportedURL.path) else {
            let altURL = config.projectRoot.appendingPathComponent(".build")
                .appendingPathComponent("xcresults")
                .appendingPathComponent("accessibility_tree.json")
            guard FileManager.default.fileExists(atPath: altURL.path) else { return }
            let data = try Data(contentsOf: altURL)
            let elements = try JSONDecoder().decode([UIElementSnapshot].self, from: data)
            #expect(elements.count == 38)
            return
        }

        let data = try Data(contentsOf: exportedURL)
        let elements = try JSONDecoder().decode([UIElementSnapshot].self, from: data)
        #expect(elements.count == 38)

        // Verify elem_31: Log In UAT heading
        let heading = elements.first { $0.id == "elem_31" }
        #expect(heading != nil)
        #expect(heading?.role == "staticText")
        #expect(heading?.identifier == "login-title")
        #expect(heading?.label == "Log In UAT")
        #expect(heading?.frame?.x == 140.5)
        #expect(heading?.frame?.y == 216.075488372093)
        #expect(heading?.frame?.width == 121.0)
        #expect(heading?.frame?.height == 27.0)

        // Verify elem_35: Log In button
        let button = elements.first { $0.id == "elem_35" }
        #expect(button != nil)
        #expect(button?.role == "button")
        #expect(button?.identifier == "login-button")
        #expect(button?.label == "Log In")
        #expect(button?.frame?.x == 18.666666666666664)
        #expect(button?.frame?.y == 438.6666666666667)
        #expect(button?.frame?.width == 364.66666666666663)
        #expect(button?.frame?.height == 41.33333333333326)

        // Disambiguation assertions
        #expect(heading?.id != button?.id)
        #expect(heading?.role != button?.role)
        #expect(heading?.identifier != button?.identifier)
        #expect(heading?.label != button?.label)
        #expect(heading?.frame != button?.frame)
    }


    // MARK: - End-to-End Action Pipeline and Approval Dispatch Tests (SCENARIO-LANG-SHEET, via SEC)
}
