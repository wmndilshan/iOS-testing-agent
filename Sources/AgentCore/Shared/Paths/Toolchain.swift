import Foundation

/// Absolute location of the Apple developer tool the agent shells out to for simulator control.
public enum Toolchain {
    public static let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
}
