import Foundation

/// What an operator needs to know about a screen, and little else: the controls it can use, the text it can read, and the state that changes
/// what it should do (a keyboard, a focused field, an alert or sheet). A raw accessibility tree is hundreds of nodes; this is a few dozen lines.
public struct ScreenDigest: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        /// The number used to refer to it in this digest (`#12`). Only meaningful together with the digest's version.
        public let handle: Int
        /// Role, identifier and label: the same element on a later screen has the same key, which is how changes are found.
        public let key: String
        /// Which of several elements with the same key this is, in reading order.
        public let occurrence: Int
        public let role: String
        public let label: String
        public let identifier: String?
        public let value: String?
        public let x: Int
        public let y: Int
        public let width: Int
        public let height: Int
        public let isOnScreen: Bool
        public let isEnabled: Bool
        public let isSelected: Bool
    }

    public let version: Int
    public let width: Int
    public let height: Int
    public let keyboardVisible: Bool
    /// The name of the field that has the keyboard, when one does.
    public let focusedField: String?
    /// The title of an alert, sheet or popover when one covers the screen.
    public let overlay: String?
    public let controls: [Item]
    public let texts: [Item]
    /// Controls that did not fit in the line limit.
    public let omittedControls: Int
    public let omittedTexts: Int

    public var itemCount: Int { controls.count + texts.count }
}
