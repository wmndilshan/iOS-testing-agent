import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

private func context(repository: URL? = nil) -> (DeviceValidationContext, URL) {
    let root = ProductFixtures.tempDir()
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (DeviceValidationContext(projectRoot: root, repository: repository), root)
}

private func ok(_ command: DeviceCommand, _ context: DeviceValidationContext) -> DeviceCommand? { try? DeviceCommandValidator.validate(command, context: context) }

@Suite("Device command catalog")
struct DeviceCommandCatalogTests {
    @Test("Every command has exactly one catalog entry, with a unique snake_case name, a summary and words for approval")
    func complete() {
        #expect(DeviceCommandCatalog.all.count == DeviceCommandKind.allCases.count)
        #expect(Set(DeviceCommandCatalog.all.map(\.kind)) == Set(DeviceCommandKind.allCases))
        for kind in DeviceCommandKind.allCases {
            #expect(kind.rawValue.range(of: #"^[a-z]+(_[a-z]+)*$"#, options: .regularExpression) != nil, "\(kind.rawValue)")
            let spec = DeviceCommandCatalog.spec(for: kind)
            #expect(!spec.summary.isEmpty && !DeviceCommandCatalog.phrase(DeviceCommand(kind)).isEmpty)
            #expect(spec.params.allSatisfy { !$0.help.isEmpty }, "\(kind.rawValue)")
        }
    }

    @Test("The destructive commands are exactly these, and nothing destructive is read-only or reversible")
    func destructiveSet() {
        let destructive = Set(DeviceCommandCatalog.all.filter { $0.risk == .destructive }.map(\.kind.rawValue))
        #expect(destructive == ["uninstall_app", "clear_keychain", "clear_photos", "clear_contacts", "crash_delete", "file_remove", "erase_target"])
    }

    @Test("Observation commands are read-only and every other kind of command is not")
    func readOnlySet() {
        let readOnly = DeviceCommandCatalog.all.filter { $0.risk == .readOnly }
        #expect(readOnly.allSatisfy { $0.group == .observe })
        #expect(DeviceCommandCatalog.all.filter { $0.group == .input }.allSatisfy { $0.risk == .reversible })
    }

    @Test("There is no way to pass a command line: no argument is called command, shell, args or script")
    func noEscapeHatch() {
        let banned: Set<String> = ["command", "shell", "args", "script", "argv", "cmd", "arguments"]
        for spec in DeviceCommandCatalog.all { #expect(Set(spec.params.map(\.name)).isDisjoint(with: banned), "\(spec.kind.rawValue)") }
    }

    @Test("Approval wording names the arguments")
    func wording() {
        #expect(DeviceCommandCatalog.phrase(DeviceCommand(.tap, ["label": .string("Log In")])) == "Tap “Log In”")
        #expect(DeviceCommandCatalog.phrase(DeviceCommand(.tap, ["x": .number(10), "y": .number(20)])) == "Tap (10, 20)")
        #expect(DeviceCommandCatalog.phrase(DeviceCommand(.pressButton, ["button": .string("HOME")])) == "Press the HOME button")
        #expect(DeviceCommandCatalog.phrase(DeviceCommand(.setLocation, ["latitude": .number(37.33), "longitude": .number(-122.03)])) == "Set the location to 37.33, -122.03")
        #expect(DeviceCommandCatalog.phrase(DeviceCommand(.uninstallApp, ["bundle_id": .string("com.apple.mobilesafari")])).contains("delete its data"))
    }
}

@Suite("Device command validation")
struct DeviceCommandValidationTests {
    @Test("Unknown arguments and missing required ones are refused with the reason")
    func shape() {
        let (c, _) = context()
        #expect(throws: DeviceControlError.self) { try DeviceCommandValidator.validate(DeviceCommand(.openURL, ["url": .string("https://x.com"), "extra": .bool(true)]), context: c) }
        #expect(throws: DeviceControlError.self) { try DeviceCommandValidator.validate(DeviceCommand(.openURL), context: c) }
        #expect(ok(DeviceCommand(.openURL, ["url": .string("https://example.com/a?b=1")]), c) != nil)
    }

    @Test("Numbers are range-checked, text numbers are accepted, and a whole number is required where asked")
    func numbers() {
        let (c, _) = context()
        #expect(ok(DeviceCommand(.describePoint, ["x": .string("120"), "y": .number(300)]), c)?.integer("x") == 120)
        #expect(ok(DeviceCommand(.describePoint, ["x": .number(-1), "y": .number(3)]), c) == nil)
        #expect(ok(DeviceCommand(.describePoint, ["x": .number(1.5), "y": .number(3)]), c) == nil)
        #expect(ok(DeviceCommand(.setLocation, ["latitude": .number(91), "longitude": .number(0)]), c) == nil)
        #expect(ok(DeviceCommand(.setLocation, ["latitude": .number(-33.86), "longitude": .number(151.2)]), c) != nil)
    }

    @Test("A choice is matched without regard to case and normalized; others are refused")
    func choices() {
        let (c, _) = context()
        #expect(ok(DeviceCommand(.pressButton, ["button": .string("home")]), c)?.string("button") == "HOME")
        #expect(ok(DeviceCommand(.pressButton, ["button": .string("explode")]), c) == nil)
        #expect(ok(DeviceCommand(.approvePermission, ["bundle_id": .string("com.apple.mobilesafari"), "permission": .string("Camera")]), c)?.string("permission") == "camera")
    }

    @Test("Bundle ids and URLs: file, javascript and data URLs and malformed ids are refused")
    func identifiers() {
        let (c, _) = context()
        #expect(ok(DeviceCommand(.launchApp, ["bundle_id": .string("com.apple.mobilesafari")]), c) != nil)
        #expect(ok(DeviceCommand(.launchApp, ["bundle_id": .string("not a bundle; rm -rf /")]), c) == nil)
        for url in ["file:///etc/passwd", "javascript:alert(1)", "data:text/html,hi", "no-scheme", ""] {
            #expect(ok(DeviceCommand(.openURL, ["url": .string(url)]), c) == nil, "\(url)")
        }
        #expect(ok(DeviceCommand(.openURL, ["url": .string("myapp://orders/42")]), c) != nil)
    }

    @Test("A tap needs a label, an identifier, or both coordinates")
    func selectors() {
        let (c, _) = context()
        #expect(ok(DeviceCommand(.tap), c) == nil)
        #expect(ok(DeviceCommand(.tap, ["x": .number(10)]), c) == nil)
        #expect(ok(DeviceCommand(.tap, ["label": .string("Save")]), c) != nil)
        #expect(ok(DeviceCommand(.tap, ["identifier": .string("save-button")]), c) != nil)
        #expect(ok(DeviceCommand(.tap, ["x": .number(10), "y": .number(20)]), c) != nil)
    }

    @Test("Device paths stay inside the container: no leading slash, no parent steps")
    func devicePaths() {
        let (c, _) = context()
        func list(_ path: String) -> DeviceCommand? { ok(DeviceCommand(.fileList, ["bundle_id": .string("com.apple.mobilesafari"), "path": .string(path)]), c) }
        #expect(list("Documents/reports") != nil)
        #expect(list("/etc") == nil && list("../other") == nil && list("Documents/../../x") == nil)
    }

    @Test("Host files must exist inside the project or the repository, and a secret is never sent")
    func hostFiles() throws {
        let repository = ProductFixtures.tempDir()
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let (c, root) = context(repository: repository)
        let inside = root.appendingPathComponent("photo.png"); try Data("x".utf8).write(to: inside)
        let inRepo = repository.appendingPathComponent("clip.mov"); try Data("x".utf8).write(to: inRepo)
        let secret = root.appendingPathComponent(".env"); try Data("KEY=1".utf8).write(to: secret)
        let key = root.appendingPathComponent("signing.p12"); try Data("x".utf8).write(to: key)
        let outside = ProductFixtures.tempDir(); try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let elsewhere = outside.appendingPathComponent("a.png"); try Data("x".utf8).write(to: elsewhere)

        func add(_ path: String) -> DeviceCommand? { ok(DeviceCommand(.addMedia, ["path": .string(path)]), c) }
        #expect(add(inside.path) != nil && add("photo.png") != nil, "a relative path is read from the project")
        #expect(add(inRepo.path) != nil)
        #expect(add(elsewhere.path) == nil, "outside both folders")
        #expect(add(secret.path) == nil && add(key.path) == nil)
        #expect(add(root.appendingPathComponent("missing.png").path) == nil)
        let link = root.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)
        #expect(add(link.path) == nil, "a symbolic link that leaves the folders is followed and refused")
    }

    @Test("A notification payload must be a JSON object")
    func payload() {
        let (c, _) = context()
        func send(_ payload: String) -> DeviceCommand? { ok(DeviceCommand(.sendNotification, ["bundle_id": .string("com.apple.mobilesafari"), "payload": .string(payload)]), c) }
        #expect(send("{\"aps\":{\"alert\":\"Hi\"}}") != nil)
        #expect(send("[1,2]") == nil && send("not json") == nil)
    }
}

@Suite("Device approval policy")
struct DeviceControlPolicyTests {
    @Test("Read-only runs; reversible asks until the chat is allowed; destructive always asks and never offers a chat grant")
    func table() {
        let none = DeviceGrants(), allowed = DeviceGrants(allowsReversible: true)
        #expect(DeviceControlPolicy.decision(for: .readOnly, grants: none) == .run)
        #expect(DeviceControlPolicy.decision(for: .reversible, grants: none) == .ask(offerChatGrant: true))
        #expect(DeviceControlPolicy.decision(for: .reversible, grants: allowed) == .run)
        #expect(DeviceControlPolicy.decision(for: .destructive, grants: none) == .ask(offerChatGrant: false))
        #expect(DeviceControlPolicy.decision(for: .destructive, grants: allowed) == .ask(offerChatGrant: false))
    }
}
