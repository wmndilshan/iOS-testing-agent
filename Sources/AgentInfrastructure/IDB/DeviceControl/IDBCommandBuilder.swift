import Foundation
import AgentCore

/// One process to run for a command: an idb call (against the target, or global), or a simctl call. Always an argument list, never a shell string.
enum IDBInvocation: Equatable {
    case idb(command: [String], options: [String] = [], positional: [String] = [])
    case idbGlobal(command: [String], options: [String] = [])
    case simctl([String])
}

/// Turns a validated `DeviceCommand` into the idb or simctl calls that carry it out. Pure: the one place that knows idb's flags, and
/// the thing the tests check line by line. Commands that need to look at the screen first (a tap by label, a scroll) are given their
/// coordinates before they get here.
enum IDBCommandBuilder {
    /// HID usage codes for `idb ui key`.
    static let keyCodes: [String: String] = ["return": "40", "escape": "41", "delete": "42", "tab": "43", "space": "44",
                                              "right": "79", "left": "80", "down": "81", "up": "82"]

    enum BuildError: Error, Equatable { case missing(String), needsLookup(DeviceCommandKind) }

    /// `udid` is for the simctl forms; `outputPath` is where a screenshot or a pulled file goes (chosen by the caller, inside `.runs/device`).
    static func invocations(for command: DeviceCommand, udid: String, outputPath: String? = nil) throws -> [IDBInvocation] {
        func s(_ name: String) throws -> String {
            if let value = command.string(name) { return value }
            if let number = command.number(name) { return number.rounded() == number ? String(Int(number)) : String(number) }
            throw BuildError.missing(name)
        }
        func n(_ name: String) throws -> String {
            guard let value = command.number(name) else { throw BuildError.missing(name) }
            return value.rounded() == value ? String(Int(value)) : String(value)
        }
        func container() throws -> [String] { ["--bundle-id", try s("bundle_id")] }
        func point() throws -> [String] { [try n("x"), try n("y")] }

        switch command.kind {
        // Observe
        case .listTargets: return [.idbGlobal(command: ["list-targets"], options: ["--json"] + (command.string("only").map { ["--only", $0] } ?? []))]
        case .describeTarget: return [.idb(command: ["describe"], options: ["--json"])]
        case .describeScreen: return [.idb(command: ["ui", "describe-all"])]
        case .readScreen, .find, .look, .waitFor, .readElement, .scrollTo: throw BuildError.needsLookup(command.kind)
        case .describePoint: return [.idb(command: ["ui", "describe-point"], positional: try point())]
        case .screenshot: return [.idb(command: ["screenshot"], positional: [try pathOrThrow(outputPath)])]
        case .listApps: return [.idb(command: ["list-apps"], options: ["--json"])]
        case .readLog:
            var arguments = ["spawn", udid, "log", "show", "--last", "\(command.integer("seconds") ?? 30)s", "--style", "compact"]
            if let process = command.string("process") { arguments += ["--predicate", "process == \"\(process.filter { $0.isLetter || $0.isNumber || "._- ".contains($0) })\""] }
            return [.simctl(arguments)]
        case .crashList: return [.idb(command: ["crash", "list"], options: command.string("bundle_id").map { ["--bundle-id", $0] } ?? [])]
        case .crashShow: return [.idb(command: ["crash", "show"], positional: [try s("name")])]
        case .getSetting: return [.idb(command: ["get"], options: command.string("domain").map { ["--domain", $0] } ?? [], positional: [try s("name")])]
        case .listNotifications: return [.idb(command: ["notification", "list"], positional: [try s("bundle_id")])]
        case .fileList: return [.idb(command: ["file", "ls"], options: try container(), positional: [try s("path")])]
        case .fileRead: return [.idb(command: ["file", "read"], options: try container(), positional: [try s("path")])]
        case .filePull: return [.idb(command: ["file", "pull"], options: try container(), positional: [try s("path"), try pathOrThrow(outputPath)])]
        // Input (a point is required here: a label has been resolved by now)
        case .tap: return [.idb(command: ["ui", "tap"], positional: try point())]
        case .doubleTap: return [.idb(command: ["ui", "tap"], positional: try point()), .idb(command: ["ui", "tap"], positional: try point())]
        case .longPress: return [.idb(command: ["ui", "tap"], options: ["--duration", command.number("seconds").map { String($0) } ?? "1.0"], positional: try point())]
        case .swipe:
            return [.idb(command: ["ui", "swipe"], options: command.number("seconds").map { ["--duration", String($0)] } ?? [], positional: [try n("x1"), try n("y1"), try n("x2"), try n("y2")])]
        case .scroll: throw BuildError.needsLookup(.scroll)
        case .pinch: return [.idb(command: ["ui", "pinch"], positional: try point() + [try n("scale")])]
        case .typeText: return [.idb(command: ["ui", "text"], positional: [try s("text")])]
        case .pressKey:
            guard let code = keyCodes[try s("key").lowercased()] else { throw BuildError.missing("key") }
            return [.idb(command: ["ui", "key"], positional: [code])]
        case .pressButton: return [.idb(command: ["ui", "button"], positional: [try s("button")])]
        // Apps
        case .openURL: return [.idb(command: ["open"], positional: [try s("url")])]
        case .launchApp: return [.idb(command: ["launch"], options: ["-f"], positional: [try s("bundle_id")])]
        case .terminateApp: return [.idb(command: ["terminate"], positional: [try s("bundle_id")])]
        case .installApp: return [.idb(command: ["install"], positional: [try s("path")])]
        case .uninstallApp: return [.idb(command: ["uninstall"], positional: [try s("bundle_id")])]
        // Environment
        case .setLocation: return [.idb(command: ["set-location"], positional: [try n("latitude"), try n("longitude")])]
        case .approvePermission: return [.idb(command: ["approve"], positional: [try s("bundle_id"), try s("permission")])]
        case .revokePermission: return [.idb(command: ["revoke"], positional: [try s("bundle_id"), try s("permission")])]
        case .sendNotification: return [.idb(command: ["notification", "send"], positional: [try s("bundle_id"), try s("payload")])]
        case .setAppearance: return [.simctl(["ui", udid, "appearance", try s("mode")])]
        case .setSetting: return [.idb(command: ["set"], options: command.string("domain").map { ["--domain", $0] } ?? [], positional: [try s("name"), try s("value")])]
        case .addMedia: return [.idb(command: ["add-media"], positional: [try s("path")])]
        case .updateContacts: return [.idb(command: ["contacts", "update"], positional: [try s("path")])]
        case .simulateMemoryWarning: return [.idb(command: ["simulate-memory-warning"])]
        // Files
        case .filePush: return [.idb(command: ["file", "push"], options: try container(), positional: [try s("source"), try s("path")])]
        case .fileMakeDirectory: return [.idb(command: ["file", "mkdir"], options: try container(), positional: [try s("path")])]
        case .fileMove: return [.idb(command: ["file", "mv"], options: try container(), positional: [try s("from"), try s("to")])]
        // Device
        case .boot: return [.simctl(["boot", udid])]
        case .shutdown: return [.simctl(["shutdown", udid])]
        // Destructive
        case .clearKeychain: return [.idb(command: ["clear-keychain"])]
        case .clearPhotos: return [.idb(command: ["photos", "clear"])]
        case .clearContacts: return [.idb(command: ["contacts", "clear"])]
        case .crashDelete: return [.idb(command: ["crash", "delete"], positional: [try s("name")])]
        case .fileRemove: return [.idb(command: ["file", "rm"], options: try container(), positional: [try s("path")])]
        case .eraseTarget: return [.simctl(["erase", udid])]
        }
    }

    private static func pathOrThrow(_ path: String?) throws -> String {
        guard let path else { throw BuildError.missing("output path") }
        return path
    }
}
