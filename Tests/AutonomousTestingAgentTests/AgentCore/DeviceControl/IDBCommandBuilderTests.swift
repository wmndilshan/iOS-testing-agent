import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("idb command builder")
struct IDBCommandBuilderTests {
    private let udid = "710E5B5D-C7CF-4CC7-8A56-CA363D1565BA"

    private func build(_ kind: DeviceCommandKind, _ arguments: [String: DeviceValue] = [:], output: String? = nil) throws -> [IDBInvocation] {
        try IDBCommandBuilder.invocations(for: DeviceCommand(kind, arguments), udid: udid, outputPath: output)
    }

    @Test("Observation commands")
    func observe() throws {
        #expect(try build(.listTargets, ["only": .string("simulator")]) == [.idbGlobal(command: ["list-targets"], options: ["--json", "--only", "simulator"])])
        #expect(try build(.describeTarget) == [.idb(command: ["describe"], options: ["--json"])])
        #expect(try build(.describeScreen) == [.idb(command: ["ui", "describe-all"])])
        #expect(try build(.describePoint, ["x": .number(120), "y": .number(300)]) == [.idb(command: ["ui", "describe-point"], positional: ["120", "300"])])
        #expect(try build(.screenshot, output: "/tmp/s.png") == [.idb(command: ["screenshot"], positional: ["/tmp/s.png"])])
        #expect(try build(.listApps) == [.idb(command: ["list-apps"], options: ["--json"])])
        #expect(try build(.crashList, ["bundle_id": .string("com.apple.mobilesafari")]) == [.idb(command: ["crash", "list"], options: ["--bundle-id", "com.apple.mobilesafari"])])
        #expect(try build(.crashShow, ["name": .string("App.ips")]) == [.idb(command: ["crash", "show"], positional: ["App.ips"])])
        #expect(try build(.getSetting, ["name": .string("AppleLanguages"), "domain": .string("com.apple.x")]) == [.idb(command: ["get"], options: ["--domain", "com.apple.x"], positional: ["AppleLanguages"])])
        #expect(try build(.listNotifications, ["bundle_id": .string("com.apple.mobilesafari")]) == [.idb(command: ["notification", "list"], positional: ["com.apple.mobilesafari"])])
    }

    @Test("The device log is a bounded simctl call whose process filter cannot carry a quote")
    func log() throws {
        #expect(try build(.readLog, ["seconds": .number(10)]) == [.simctl(["spawn", udid, "log", "show", "--last", "10s", "--style", "compact"])])
        let filtered = try build(.readLog, ["process": .string("My App\"; drop")])
        guard case .simctl(let arguments)? = filtered.first, let index = arguments.firstIndex(of: "--predicate") else { Issue.record("no predicate"); return }
        #expect(arguments[index + 1] == "process == \"My App drop\"")
    }

    @Test("Input commands: points, durations, keys and buttons")
    func input() throws {
        let point: [String: DeviceValue] = ["x": .number(100), "y": .number(250)]
        #expect(try build(.tap, point) == [.idb(command: ["ui", "tap"], positional: ["100", "250"])])
        #expect(try build(.doubleTap, point).count == 2)
        #expect(try build(.longPress, point.merging(["seconds": .number(2)]) { $1 }) == [.idb(command: ["ui", "tap"], options: ["--duration", "2.0"], positional: ["100", "250"])])
        #expect(try build(.swipe, ["x1": .number(1), "y1": .number(2), "x2": .number(3), "y2": .number(4), "seconds": .number(0.5)])
                == [.idb(command: ["ui", "swipe"], options: ["--duration", "0.5"], positional: ["1", "2", "3", "4"])])
        #expect(try build(.pinch, point.merging(["scale": .number(2)]) { $1 }) == [.idb(command: ["ui", "pinch"], positional: ["100", "250", "2"])])
        #expect(try build(.typeText, ["text": .string("-hello world")]) == [.idb(command: ["ui", "text"], positional: ["-hello world"])])
        #expect(try build(.pressKey, ["key": .string("return")]) == [.idb(command: ["ui", "key"], positional: ["40"])])
        #expect(try build(.pressButton, ["button": .string("HOME")]) == [.idb(command: ["ui", "button"], positional: ["HOME"])])
        #expect(throws: IDBCommandBuilder.BuildError.self) { try IDBCommandBuilder.invocations(for: DeviceCommand(.scroll, ["direction": .string("down")]), udid: udid) }
        #expect(throws: IDBCommandBuilder.BuildError.self) { try IDBCommandBuilder.invocations(for: DeviceCommand(.tap, ["label": .string("Save")]), udid: udid) }
    }

    @Test("Apps, environment, files and device lifecycle")
    func others() throws {
        let app: [String: DeviceValue] = ["bundle_id": .string("com.apple.mobilesafari")]
        #expect(try build(.openURL, ["url": .string("https://example.com")]) == [.idb(command: ["open"], positional: ["https://example.com"])])
        #expect(try build(.launchApp, app) == [.idb(command: ["launch"], options: ["-f"], positional: ["com.apple.mobilesafari"])])
        #expect(try build(.terminateApp, app) == [.idb(command: ["terminate"], positional: ["com.apple.mobilesafari"])])
        #expect(try build(.installApp, ["path": .string("/p/App.app")]) == [.idb(command: ["install"], positional: ["/p/App.app"])])
        #expect(try build(.setLocation, ["latitude": .number(-33.86), "longitude": .number(151.2)]) == [.idb(command: ["set-location"], positional: ["-33.86", "151.2"])])
        #expect(try build(.approvePermission, app.merging(["permission": .string("camera")]) { $1 }) == [.idb(command: ["approve"], positional: ["com.apple.mobilesafari", "camera"])])
        #expect(try build(.revokePermission, app.merging(["permission": .string("photos")]) { $1 }) == [.idb(command: ["revoke"], positional: ["com.apple.mobilesafari", "photos"])])
        #expect(try build(.setAppearance, ["mode": .string("dark")]) == [.simctl(["ui", udid, "appearance", "dark"])])
        #expect(try build(.addMedia, ["path": .string("/p/a.png")]) == [.idb(command: ["add-media"], positional: ["/p/a.png"])])
        #expect(try build(.fileList, app.merging(["path": .string("Documents")]) { $1 }) == [.idb(command: ["file", "ls"], options: ["--bundle-id", "com.apple.mobilesafari"], positional: ["Documents"])])
        #expect(try build(.filePull, app.merging(["path": .string("Documents/a.txt")]) { $1 }, output: "/out") == [.idb(command: ["file", "pull"], options: ["--bundle-id", "com.apple.mobilesafari"], positional: ["Documents/a.txt", "/out"])])
        #expect(try build(.boot) == [.simctl(["boot", udid])] && (try build(.shutdown)) == [.simctl(["shutdown", udid])])
    }

    @Test("Destructive commands")
    func destructive() throws {
        let app: [String: DeviceValue] = ["bundle_id": .string("com.apple.mobilesafari")]
        #expect(try build(.uninstallApp, app) == [.idb(command: ["uninstall"], positional: ["com.apple.mobilesafari"])])
        #expect(try build(.clearKeychain) == [.idb(command: ["clear-keychain"])])
        #expect(try build(.clearPhotos) == [.idb(command: ["photos", "clear"])])
        #expect(try build(.clearContacts) == [.idb(command: ["contacts", "clear"])])
        #expect(try build(.crashDelete, ["name": .string("App.ips")]) == [.idb(command: ["crash", "delete"], positional: ["App.ips"])])
        #expect(try build(.fileRemove, app.merging(["path": .string("tmp")]) { $1 }) == [.idb(command: ["file", "rm"], options: ["--bundle-id", "com.apple.mobilesafari"], positional: ["tmp"])])
        #expect(try build(.eraseTarget) == [.simctl(["erase", udid])])
    }

    @Test("Every command kind can be built, so none is left without an implementation")
    func everyKindBuilds() throws {
        func value(_ param: DeviceParam) -> DeviceValue {
            switch param.type {
            case .integer(let range): .number(Double(range.lowerBound + 1))
            case .number(let range): .number(range.lowerBound + 0.5)
            case .choice(let options): .string(options[0])
            case .bundleID: .string("com.apple.mobilesafari")
            case .url: .string("https://example.com")
            case .json: .string("{}")
            default: .string("value")
            }
        }
        for spec in DeviceCommandCatalog.all {
            var arguments: [String: DeviceValue] = [:]
            for param in spec.params where param.required { arguments[param.name] = value(param) }
            if [.tap, .doubleTap, .longPress].contains(spec.kind) { arguments["x"] = .number(1); arguments["y"] = .number(2) }
            if [.scroll, .scrollTo, .readScreen, .find, .look, .waitFor, .readElement].contains(spec.kind) { continue }   // look at the screen first; covered by the device-control tests
            let built = try IDBCommandBuilder.invocations(for: DeviceCommand(spec.kind, arguments), udid: udid, outputPath: "/out")
            #expect(!built.isEmpty, "\(spec.kind.rawValue)")
        }
    }
}
