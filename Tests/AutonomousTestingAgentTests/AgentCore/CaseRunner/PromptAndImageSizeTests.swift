import Testing
import Foundation
import ImageIO
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition
@testable import AgentEngine

@Suite("Prompt and screenshot size")
struct PromptAndImageSizeTests {
    private func vocabulary(_ elements: [ObservedElementReference]) -> ObservedUIVocabulary {
        ObservedUIVocabulary(snapshotID: "snap_1", bundleID: "b", elements: elements)
    }

    private func element(_ id: String?, _ role: String, _ label: String?, hittable: Bool = true, enabled: Bool = true) -> ObservedElementReference {
        ObservedElementReference(elementID: UUID().uuidString, accessibilityIdentifier: id, label: label, role: role,
                                 state: ObservedElementState(isEnabled: enabled, isHittable: hittable, isSelected: nil))
    }

    @Test("Each element is one line: role | identifier | label")
    func testOneLinePerElement() {
        let block = vocabulary([element("login-button", "button", "Log In"), element(nil, "staticText", "Welcome")]).promptBlock()
        #expect(block.contains("\nbutton | login-button | Log In\n"))
        #expect(block.contains("\nstaticText | - | Welcome\n"))
    }

    @Test("Repeated elements are listed once and nameless ones are left out")
    func testDedupeAndNameless() {
        let block = vocabulary([element(nil, "link", "Resin"), element(nil, "link", "Resin"), element(nil, "other", nil)]).promptBlock()
        #expect(block.components(separatedBy: "link | - | Resin").count == 2)
        #expect(!block.contains("other | - | -"))
    }

    @Test("On-screen controls come before off-screen ones, and the list is capped")
    func testOrderAndCap() {
        var elements = (0..<400).map { element("hidden-\($0)", "button", "Hidden \($0)", hittable: false) }
        elements.append(element("share-button", "button", "Share"))
        let block = vocabulary(elements).promptBlock()
        let lines = block.components(separatedBy: "\n")
        #expect(lines.firstIndex { $0.contains("share-button") }! < lines.firstIndex { $0.contains("hidden-0") }!)
        #expect(block.contains("more elements not listed"))
        #expect(lines.filter { $0.hasPrefix("button |") }.count <= 170)
    }

    @Test("A label is listed whole or not at all, because labels are matched exactly")
    func testLongLabelsAreNeverCut() {
        let medium = String(repeating: "m", count: 100)
        let paragraph = String(repeating: "p", count: 500)
        let block = vocabulary([element(nil, "link", medium), element(nil, "staticText", paragraph)]).promptBlock()
        #expect(block.contains(medium))
        #expect(!block.contains("ppp"))
        #expect(!block.contains("…"))
    }

    @Test("A screenshot is shrunk to a JPEG no taller than the limit")
    func testScreenshotCompression() throws {
        let context = CGContext(data: nil, width: 1206, height: 2622, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1206, height: 2622))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
        let jpeg = try #require(ScreenshotCompressor.jpeg(from: output as Data, maxPixels: 1100))
        let source = CGImageSourceCreateWithData(jpeg as CFData, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        #expect((properties[kCGImagePropertyPixelHeight] as! Int) <= 1100)
        #expect(jpeg.count < (output as Data).count)
    }
}

private final class NamedClient: LLMClientProtocol, @unchecked Sendable {
    let name: String
    init(_ name: String) { self.name = name }
    func complete(_ request: LLMRequest) async throws -> String { name }
    func sendPrompt(_ prompt: String) async throws -> String { name }
}

@Suite("Escalating client")
struct EscalatingLLMClientTests {
    @Test("The first request goes to the fast model and every later one to the strong model")
    func testEscalation() async throws {
        let client = EscalatingLLMClient(fast: NamedClient("fast"), strong: NamedClient("strong"))
        #expect(try await client.sendPrompt("a") == "fast")
        #expect(try await client.complete(LLMRequest(messages: [LLMMessage(text: "b")])) == "strong")
        #expect(try await client.sendPrompt("c") == "strong")
    }

    @Test("Each planning attempt gets its own client, so each starts with the fast model")
    func testFreshClientStartsFast() async throws {
        let fast = NamedClient("fast"), strong = NamedClient("strong")
        _ = try await EscalatingLLMClient(fast: fast, strong: strong).sendPrompt("x")
        #expect(try await EscalatingLLMClient(fast: fast, strong: strong).sendPrompt("y") == "fast")
    }
}

@Suite("Step text")
struct StepTextTests {
    @Test(arguments: [("Tap the Amazon search bar and search for men watches", true), ("Open the menu, then tap Share", true),
                      ("Take a screenshot of the search results", false), ("Tap the Collection button", false)])
    func testCompound(text: String, expected: Bool) {
        #expect(StepText(text + ". Expected: x").isCompound == expected)
    }
}

@Suite("Verify-only detection")
struct VerifyOnlyDetectionTests {
    @Test(arguments: [("Validate collection components", true), ("Verify Test1 remains active and MSFT is visible", true),
                      ("Confirm collection screen is ready", true), ("Check grid view by scrolling horizontally the grid", false),
                      ("Verify the result after tapping Save", false), ("Check grid column labels", true)])
    func testVerifiesOnly(text: String, expected: Bool) {
        #expect(StepText(text + ". Expected: x").verifiesOnly == expected)
    }
}
