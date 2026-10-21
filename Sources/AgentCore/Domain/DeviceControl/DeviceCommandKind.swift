import Foundation

/// Everything the agents may ask a device to do. A closed list: there is no way to name a command that is not here, and none that runs
/// arbitrary text. Each kind's risk, arguments and wording live in `DeviceCommandCatalog`.
public enum DeviceCommandKind: String, CaseIterable, Codable, Sendable {
    // Observe
    case listTargets = "list_targets"
    case describeTarget = "describe_target"
    case describeScreen = "describe_screen"
    case describePoint = "describe_point"
    case readScreen = "read_screen"
    case look
    case find
    case waitFor = "wait_for"
    case readElement = "read_element"
    case screenshot
    case listApps = "list_apps"
    case readLog = "read_log"
    case crashList = "crash_list"
    case crashShow = "crash_show"
    case getSetting = "get_setting"
    case listNotifications = "list_notifications"
    case fileList = "file_list"
    case fileRead = "file_read"
    case filePull = "file_pull"
    // Input
    case tap
    case doubleTap = "double_tap"
    case longPress = "long_press"
    case swipe
    case scroll
    case scrollTo = "scroll_to"
    case pinch
    case typeText = "type_text"
    case pressKey = "press_key"
    case pressButton = "press_button"
    // Apps
    case openURL = "open_url"
    case launchApp = "launch_app"
    case terminateApp = "terminate_app"
    case installApp = "install_app"
    // Environment
    case setLocation = "set_location"
    case approvePermission = "approve_permission"
    case revokePermission = "revoke_permission"
    case sendNotification = "send_notification"
    case setAppearance = "set_appearance"
    case setSetting = "set_setting"
    case addMedia = "add_media"
    case updateContacts = "update_contacts"
    case simulateMemoryWarning = "simulate_memory_warning"
    // Files
    case filePush = "file_push"
    case fileMakeDirectory = "file_mkdir"
    case fileMove = "file_move"
    // Device
    case boot
    case shutdown
    // Destructive
    case uninstallApp = "uninstall_app"
    case clearKeychain = "clear_keychain"
    case clearPhotos = "clear_photos"
    case clearContacts = "clear_contacts"
    case crashDelete = "crash_delete"
    case fileRemove = "file_remove"
    case eraseTarget = "erase_target"
}
