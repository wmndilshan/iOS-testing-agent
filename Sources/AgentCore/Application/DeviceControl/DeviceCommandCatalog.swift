import Foundation

public enum DeviceParamType: Sendable, Equatable {
    case text(maxLength: Int)
    case integer(ClosedRange<Int>)
    case number(ClosedRange<Double>)
    case choice([String])
    case bundleID
    case url
    /// A file on this Mac that may be sent to the device: inside the project or the chosen repository.
    case hostFile
    /// A path inside an app's container on the device: relative, no `..`.
    case devicePath
    case json
}

public struct DeviceParam: Sendable, Equatable {
    public let name: String
    public let type: DeviceParamType
    public let required: Bool
    public let help: String

    init(_ name: String, _ type: DeviceParamType, required: Bool = true, _ help: String) {
        self.name = name
        self.type = type
        self.required = required
        self.help = help
    }
}

public struct DeviceCommandSpec: Sendable {
    public let kind: DeviceCommandKind
    public let group: DeviceCommandGroup
    public let risk: DeviceCommandRisk
    public let support: DeviceTargetSupport
    public let summary: String
    public let params: [DeviceParam]
    /// Arguments of which at least one of these sets must be given completely (a tap needs x and y, or a label, or an identifier).
    let alternatives: [[String]]
}

/// The one list of what a device command is: its name, group, risk, whether it works on a real device, its arguments and its wording. The agent
/// tools, the approval text, the docs and the tests all read it; nothing else decides what a command may do.
public enum DeviceCommandCatalog {
    private static let coordinate: DeviceParamType = .integer(0...5000)
    private static let permissions = ["photos", "camera", "contacts", "url", "location", "notification", "microphone"]
    private static let keys = ["return", "delete", "escape", "tab", "space", "up", "down", "left", "right"]
    private static let buttons = ["HOME", "LOCK", "SIDE_BUTTON", "SIRI", "VOLUME_UP", "VOLUME_DOWN", "APPLE_PAY"]
    private static let selector: [DeviceParam] = [
        DeviceParam("label", .text(maxLength: 120), required: false, "Visible label or accessibility label of the element"),
        DeviceParam("identifier", .text(maxLength: 160), required: false, "Accessibility identifier of the element"),
        DeviceParam("handle", .text(maxLength: 8), required: false, "The #number of an element from read_screen or find, for example #4"),
        DeviceParam("x", coordinate, required: false, "X in screen points (with y)"),
        DeviceParam("y", coordinate, required: false, "Y in screen points (with x)"),
    ]
    private static let selectorAlternatives = [["handle"], ["label"], ["identifier"], ["x", "y"]]
    private static let app = DeviceParam("bundle_id", .bundleID, "Bundle id of the app, for example com.apple.mobilesafari")

    private static func spec(_ kind: DeviceCommandKind, _ group: DeviceCommandGroup, _ risk: DeviceCommandRisk, _ summary: String, support: DeviceTargetSupport = .anyTarget,
                             _ params: [DeviceParam] = [], alternatives: [[String]] = []) -> DeviceCommandSpec {
        DeviceCommandSpec(kind: kind, group: group, risk: risk, support: support, summary: summary, params: params, alternatives: alternatives)
    }

    public static let all: [DeviceCommandSpec] = [
        // Observe
        spec(.listTargets, .observe, .readOnly, "List the simulators and devices idb can reach", [DeviceParam("only", .choice(["simulator", "device"]), required: false, "Only this kind")]),
        spec(.describeTarget, .observe, .readOnly, "Describe the target: name, OS, state"),
        spec(.describeScreen, .observe, .readOnly, "List what is on screen: labels, identifiers, types and positions of the elements. Start here, then act by label.",
             [DeviceParam("filter", .choice(["all", "interactable"]), required: false, "Only elements that can be tapped")]),
        spec(.readScreen, .observe, .readOnly, "The screen as a short list: controls with #numbers and positions, then readable text. After an action it returns only what changed. Prefer this to describe_screen.",
             [DeviceParam("mode", .choice(["auto", "full", "diff", "state"]), required: false, "auto (default): changes since the last read when the screen is the same, else everything. state: the changes, a line, then the whole screen"),
              DeviceParam("query", .text(maxLength: 80), required: false, "Only elements whose text, id or role contains this"),
              DeviceParam("limit", .integer(5...120), required: false, "Most controls to list, default 40")]),
        spec(.look, .observe, .readOnly, "Look at the actual screenshot and answer a question about it in words. Slower and costlier than read_screen: use it only when the element list cannot tell you (an icon without a label, an image, a chart, a web page).",
             [DeviceParam("question", .text(maxLength: 300), "What to find out, for example “which icon is the cart?” or “is there a red badge on the Inbox tab?”")]),
        spec(.find, .observe, .readOnly, "Find elements by text, including ones scrolled out of view, with their #numbers and positions",
             [DeviceParam("text", .text(maxLength: 80), "Text to look for in labels, ids and values"), DeviceParam("role", .text(maxLength: 30), required: false, "Only this kind of element, for example button")]),
        spec(.describePoint, .observe, .readOnly, "Describe the element at a point on screen", [DeviceParam("x", coordinate, "X in points"), DeviceParam("y", coordinate, "Y in points")]),
        spec(.waitFor, .observe, .readOnly, "Wait until some text is on screen (or gone), then return: use after an action that loads something, instead of reading again and again. Native controls only, not text inside a web page",
             [DeviceParam("text", .text(maxLength: 120), "Text, label or identifier to wait for"), DeviceParam("until", .choice(["appears", "disappears"]), required: false, "Default appears"),
              DeviceParam("timeout", .number(1...60), required: false, "Seconds to wait, default 10")]),
        spec(.readElement, .observe, .readOnly, "One element's state: its value (a switch reads 0 or 1), whether it is enabled, selected and on screen. Use it to check a toggle, a field or a selection",
             [DeviceParam("label", .text(maxLength: 120), required: false, "Visible label of the element"), DeviceParam("identifier", .text(maxLength: 160), required: false, "Accessibility identifier"),
              DeviceParam("handle", .text(maxLength: 8), required: false, "The #number from read_screen")], alternatives: [["handle"], ["label"], ["identifier"]]),
        spec(.screenshot, .observe, .readOnly, "Take a screenshot; the file path is returned"),
        spec(.listApps, .observe, .readOnly, "List the installed apps with their bundle ids and whether they are running; pass filter to keep the answer short",
             [DeviceParam("filter", .text(maxLength: 80), required: false, "Only apps whose bundle id or name contains this text")]),
        spec(.readLog, .observe, .readOnly, "Read the recent device log (simulator)", support: .simulatorOnly,
             [DeviceParam("seconds", .integer(1...300), required: false, "How far back, default 30"), DeviceParam("process", .text(maxLength: 60), required: false, "Only this process"),
              DeviceParam("lines", .integer(1...200), required: false, "Most recent lines to return, default 80")]),
        spec(.crashList, .observe, .readOnly, "List crash reports", [DeviceParam("bundle_id", .bundleID, required: false, "Only this app's")]),
        spec(.crashShow, .observe, .readOnly, "Show one crash report", [DeviceParam("name", .text(maxLength: 200), "Report name from crash_list")]),
        spec(.getSetting, .observe, .readOnly, "Read a device preference", support: .simulatorOnly,
             [DeviceParam("name", .text(maxLength: 120), "Preference name"), DeviceParam("domain", .text(maxLength: 120), required: false, "Preference domain")]),
        spec(.listNotifications, .observe, .readOnly, "List an app's notifications", support: .simulatorOnly, [app]),
        spec(.fileList, .observe, .readOnly, "List a folder inside an app's container", [app, DeviceParam("path", .devicePath, "Folder, relative to the container, for example Documents")]),
        spec(.fileRead, .observe, .readOnly, "Read a text file inside an app's container", [app, DeviceParam("path", .devicePath, "File path")]),
        spec(.filePull, .observe, .readOnly, "Copy a file from an app's container to this Mac (under .runs/device)", [app, DeviceParam("path", .devicePath, "File path")]),
        // Input
        spec(.tap, .input, .reversible, "Tap an element by label or identifier, or a point", selector, alternatives: selectorAlternatives),
        spec(.doubleTap, .input, .reversible, "Double-tap an element or a point", selector, alternatives: selectorAlternatives),
        spec(.longPress, .input, .reversible, "Press and hold an element or a point", selector + [DeviceParam("seconds", .number(0.3...5), required: false, "Hold time, default 1")], alternatives: selectorAlternatives),
        spec(.swipe, .input, .reversible, "Swipe from one point to another", [DeviceParam("x1", coordinate, "Start X"), DeviceParam("y1", coordinate, "Start Y"), DeviceParam("x2", coordinate, "End X"),
                                                                                  DeviceParam("y2", coordinate, "End Y"), DeviceParam("seconds", .number(0.1...5), required: false, "Duration")]),
        spec(.scrollTo, .input, .reversible, "Scroll until some text is on screen, then stop: for a control that is further down or across. Fails after max_scrolls",
             [DeviceParam("text", .text(maxLength: 120), "Text, label or identifier to bring into view"), DeviceParam("direction", .choice(["down", "up", "left", "right"]), required: false, "Default down"),
              DeviceParam("max_scrolls", .integer(1...20), required: false, "Default 8"), DeviceParam("within", .text(maxLength: 120), required: false, "Label of an element to scroll along, for a row that scrolls on its own (a chips or tabs row)")]),
        spec(.scroll, .input, .reversible, "Scroll the screen: 'down' shows content further down", [DeviceParam("direction", .choice(["up", "down", "left", "right"]), "Direction of the content"), DeviceParam("within", .text(maxLength: 120), required: false, "Label of an element to scroll along, for a row that scrolls on its own (a chips or tabs row)")]),
        spec(.pinch, .input, .reversible, "Pinch at a point: scale above 1 zooms in, below 1 zooms out", support: .simulatorOnly,
             [DeviceParam("x", coordinate, "X"), DeviceParam("y", coordinate, "Y"), DeviceParam("scale", .number(0.1...5), "Scale")]),
        spec(.typeText, .input, .reversible, "Type text into the focused field", [DeviceParam("text", .text(maxLength: 500), "Text to type")]),
        spec(.pressKey, .input, .reversible, "Press a key", [DeviceParam("key", .choice(keys), "Key")]),
        spec(.pressButton, .input, .reversible, "Press a hardware button", [DeviceParam("button", .choice(buttons), "Button")]),
        // Apps
        spec(.openURL, .app, .reversible, "Open a URL or deep link on the device", [DeviceParam("url", .url, "http(s) or an app's own scheme; never file:")]),
        spec(.launchApp, .app, .reversible, "Launch an app, or bring it to the front if it is running", [app]),
        spec(.terminateApp, .app, .reversible, "Stop a running app", [app]),
        spec(.installApp, .app, .reversible, "Install an .app or .ipa from this Mac (inside the project or repository)", [DeviceParam("path", .hostFile, "Path to the .app or .ipa")]),
        // Environment
        spec(.setLocation, .environment, .reversible, "Set the device location", support: .simulatorOnly,
             [DeviceParam("latitude", .number(-90...90), "Latitude"), DeviceParam("longitude", .number(-180...180), "Longitude")]),
        spec(.approvePermission, .environment, .reversible, "Grant a permission to an app without a dialog", support: .simulatorOnly, [app, DeviceParam("permission", .choice(permissions), "Permission")]),
        spec(.revokePermission, .environment, .reversible, "Revoke a permission from an app", support: .simulatorOnly, [app, DeviceParam("permission", .choice(permissions), "Permission")]),
        spec(.sendNotification, .environment, .reversible, "Deliver a push notification payload to an app", support: .simulatorOnly,
             [app, DeviceParam("payload", .json, "JSON payload, for example {\"aps\":{\"alert\":\"Hello\"}}")]),
        spec(.setAppearance, .environment, .reversible, "Switch between light and dark appearance", support: .simulatorOnly, [DeviceParam("mode", .choice(["light", "dark"]), "Appearance")]),
        spec(.setSetting, .environment, .reversible, "Write a device preference", support: .simulatorOnly,
             [DeviceParam("name", .text(maxLength: 120), "Preference name"), DeviceParam("value", .text(maxLength: 200), "Value"), DeviceParam("domain", .text(maxLength: 120), required: false, "Preference domain")]),
        spec(.addMedia, .environment, .reversible, "Add a photo or video from this Mac to the device", [DeviceParam("path", .hostFile, "Path to the image or video")]),
        spec(.updateContacts, .environment, .reversible, "Replace the contacts with a .vcf or database file from this Mac", support: .simulatorOnly, [DeviceParam("path", .hostFile, "Path to the file")]),
        spec(.simulateMemoryWarning, .environment, .reversible, "Send the foreground app a memory warning", support: .simulatorOnly),
        // Files
        spec(.filePush, .files, .reversible, "Copy a file from this Mac into an app's container", [app, DeviceParam("source", .hostFile, "File on this Mac"), DeviceParam("path", .devicePath, "Destination folder in the container")]),
        spec(.fileMakeDirectory, .files, .reversible, "Create a folder inside an app's container", [app, DeviceParam("path", .devicePath, "Folder")]),
        spec(.fileMove, .files, .reversible, "Move or rename a file inside an app's container", [app, DeviceParam("from", .devicePath, "From"), DeviceParam("to", .devicePath, "To")]),
        // Device
        spec(.boot, .system, .reversible, "Boot the simulator", support: .simulatorOnly),
        spec(.shutdown, .system, .reversible, "Shut the simulator down", support: .simulatorOnly),
        // Destructive
        spec(.uninstallApp, .app, .destructive, "Uninstall an app and delete its data", [app]),
        spec(.clearKeychain, .environment, .destructive, "Erase the keychain", support: .simulatorOnly),
        spec(.clearPhotos, .environment, .destructive, "Delete every photo and video", support: .simulatorOnly),
        spec(.clearContacts, .environment, .destructive, "Delete every contact", support: .simulatorOnly),
        spec(.crashDelete, .system, .destructive, "Delete a crash report", [DeviceParam("name", .text(maxLength: 200), "Report name")]),
        spec(.fileRemove, .files, .destructive, "Delete a file or folder inside an app's container", [app, DeviceParam("path", .devicePath, "Path")]),
        spec(.eraseTarget, .system, .destructive, "Erase the simulator: all apps and data (it must be shut down first)", support: .simulatorOnly),
    ]

    public static func spec(for kind: DeviceCommandKind) -> DeviceCommandSpec {
        // The catalog is complete by construction (a test checks every kind); the fallback only keeps this total.
        all.first { $0.kind == kind } ?? DeviceCommandSpec(kind: kind, group: .system, risk: .destructive, support: .simulatorOnly, summary: kind.rawValue, params: [], alternatives: [])
    }

    public static func specs(in group: DeviceCommandGroup) -> [DeviceCommandSpec] { all.filter { $0.group == group } }

    // MARK: Wording for the approval card

    /// The command in words, with its arguments: what the person is asked to allow.
    public static func phrase(_ command: DeviceCommand) -> String {
        func s(_ name: String) -> String { command.string(name) ?? "?" }
        func n(_ name: String) -> String { command.number(name).map { $0.rounded() == $0 ? String(Int($0)) : String($0) } ?? "?" }
        func place() -> String {
            if let handle = command.string("handle") { return "element \(handle)" }
            if let label = command.string("label") { return "“\(label)”" }
            if let identifier = command.string("identifier") { return "the element “\(identifier)”" }
            return "(\(n("x")), \(n("y")))"
        }
        switch command.kind {
        case .tap: return "Tap \(place())"
        case .doubleTap: return "Double-tap \(place())"
        case .longPress: return "Press and hold \(place())"
        case .swipe: return "Swipe from (\(n("x1")), \(n("y1"))) to (\(n("x2")), \(n("y2")))"
        case .scroll: return "Scroll \(s("direction"))"
        case .pinch: return "Pinch at (\(n("x")), \(n("y"))) by \(n("scale"))"
        case .typeText: return "Type “\(s("text"))”"
        case .pressKey: return "Press the \(s("key")) key"
        case .pressButton: return "Press the \(s("button")) button"
        case .openURL: return "Open \(s("url"))"
        case .launchApp: return "Launch \(s("bundle_id"))"
        case .terminateApp: return "Stop \(s("bundle_id"))"
        case .installApp: return "Install \(s("path"))"
        case .uninstallApp: return "Uninstall \(s("bundle_id")) and delete its data"
        case .setLocation: return "Set the location to \(n("latitude")), \(n("longitude"))"
        case .approvePermission: return "Grant \(s("permission")) permission to \(s("bundle_id"))"
        case .revokePermission: return "Revoke \(s("permission")) permission from \(s("bundle_id"))"
        case .sendNotification: return "Send a notification to \(s("bundle_id"))"
        case .setAppearance: return "Switch to \(s("mode")) appearance"
        case .setSetting: return "Set preference \(s("name")) to \(s("value"))"
        case .addMedia: return "Add \(s("path")) to the photo library"
        case .updateContacts: return "Replace the contacts with \(s("path"))"
        case .filePush: return "Copy \(s("source")) into \(s("bundle_id")) at \(s("path"))"
        case .fileMakeDirectory: return "Create folder \(s("path")) in \(s("bundle_id"))"
        case .fileMove: return "Move \(s("from")) to \(s("to")) in \(s("bundle_id"))"
        case .fileRemove: return "Delete \(s("path")) in \(s("bundle_id"))"
        case .crashDelete: return "Delete crash report \(s("name"))"
        case .clearKeychain: return "Erase the keychain"
        case .clearPhotos: return "Delete all photos and videos"
        case .clearContacts: return "Delete all contacts"
        case .eraseTarget: return "Erase the whole simulator: all apps and data"
        case .boot: return "Boot the simulator"
        case .shutdown: return "Shut the simulator down"
        case .simulateMemoryWarning: return "Send a memory warning to the foreground app"
        case .waitFor: return "Wait for “\(s("text"))” to \(s("until") == "disappears" ? "disappear" : "appear")"
        case .readElement: return "Read the state of “\(s("label").isEmpty ? (s("identifier").isEmpty ? s("handle") : s("identifier")) : s("label"))”"
        case .scrollTo: return "Scroll \(s("direction").isEmpty ? "down" : s("direction")) to “\(s("text"))”"
        default: return spec(for: command.kind).summary
        }
    }
}
