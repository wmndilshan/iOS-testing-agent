import Foundation

/// Which application an observation (or action run) was actually of, as reported by the driver that produced it.
public struct ObservedApplication: Codable, Sendable, Equatable {
    public let bundleID: String
    /// `environment`: the host chose the application; `default`: the test fell back to its built-in default.
    public let bundleSource: String
    public let foreground: Bool
    /// `UIDeviceOrientation` raw value and the main window size in points, for diagnosis.
    public let orientation: Int?
    public let windowWidth: Int?
    public let windowHeight: Int?
    /// The host's per-invocation run ID the test echoed, and the driver protocol version.
    public let runID: String?
    public let runnerProtocol: String?
    /// Read-only keyboard facts, when the driver records them (the idb driver does not yet); verification treats absence as indeterminate.
    public var keyboard: ObservedKeyboard? = nil

    public init(bundleID: String, bundleSource: String, foreground: Bool, orientation: Int? = nil, windowWidth: Int? = nil, windowHeight: Int? = nil,
                runID: String? = nil, runnerProtocol: String? = nil) {
        self.bundleID = bundleID; self.bundleSource = bundleSource; self.foreground = foreground
        self.orientation = orientation; self.windowWidth = windowWidth; self.windowHeight = windowHeight
        self.runID = runID; self.runnerProtocol = runnerProtocol
    }

    /// The observation is of `expected`, in the foreground, and the host (not a fallback) chose it.
    public func matches(expected: String) -> Bool { bundleID == expected && foreground && bundleSource == "environment" }
}

/// Keyboard facts the driver recorded with read-only queries. Visibility is derived here,
/// deterministically; anything short of a clearly visible software keyboard or a clearly absent one is `indeterminate`.
public struct ObservedKeyboard: Codable, Sendable, Equatable {
    public enum Visibility: String, Codable, Sendable { case visible, hidden, indeterminate }
    /// A software keyboard is far taller than the hardware-keyboard input assistant bar (about 45-75 pt).
    public static let minimumSoftwareKeyboardHeight = 180

    public let exists: Bool
    public let hittable: Bool?
    public let y: Int?
    public let height: Int?
    public init(exists: Bool, hittable: Bool? = nil, y: Int? = nil, height: Int? = nil) { self.exists = exists; self.hittable = hittable; self.y = y; self.height = height }

    public func visibility(windowHeight: Int?) -> Visibility {
        if !exists { return .hidden }
        guard let hittable, let y, let height, let windowHeight, windowHeight > 0 else { return .indeterminate }
        // A keyboard view whose frame lies entirely below the window is the dismissed keyboard, not a shown one.
        if y >= windowHeight { return .hidden }
        if hittable && height >= Self.minimumSoftwareKeyboardHeight && y + height <= windowHeight + 1 { return .visible }
        // On screen, but neither clearly a software keyboard nor clearly absent (for example the input assistant bar).
        return .indeterminate
    }
}

public extension ObservedApplication {
    /// The keyboard visibility of this observation, or `indeterminate` when the runner recorded no keyboard facts.
    var keyboardVisibility: ObservedKeyboard.Visibility { keyboard?.visibility(windowHeight: windowHeight) ?? .indeterminate }
}

/// The application-identity refusals the idb driver can raise: the expected app was not the one in the foreground.
public enum ApplicationIdentityVerdict: String, Codable, Sendable, CaseIterable {
    /// Another application.
    case mismatch
    /// The expected application, but not in the foreground.
    case notForeground
}

public struct Observation: Codable, Sendable, Equatable {
    /// The application the capture actually observed (live captures); nil for simulated observations.
    public var application: ObservedApplication? = nil
    /// Simulator that produced this observation. Present for genuine live captures; nil for
    /// simulations and legacy persisted observations.
    public var simulatorUDID: String? = nil
    public let snapshotID: String
    public let timestamp: Date
    public let bundleID: String
    public let appState: AppState
    public let source: ObservationSource
    public let elements: [UIElementSnapshot]
    public let screenshotPath: String?
    public let isTruncated: Bool

    public init(
        snapshotID: String = UUID().uuidString,
        timestamp: Date = Date(),
        bundleID: String,
        appState: AppState,
        source: ObservationSource = .accessibilityTree,
        elements: [UIElementSnapshot],
        screenshotPath: String? = nil,
        isTruncated: Bool = false
    ) {
        self.snapshotID = snapshotID
        self.timestamp = timestamp
        self.bundleID = bundleID
        self.appState = appState
        self.source = source
        self.elements = elements
        self.screenshotPath = screenshotPath
        self.isTruncated = isTruncated
    }

}

// MARK: - Element Locator & Disambiguation Models
