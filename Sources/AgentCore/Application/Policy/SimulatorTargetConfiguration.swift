import Foundation

/// The single deployed simulator/app selection used by the shipped composition.
/// Tests and alternate compositions inject a `SimulatorTarget` value instead of changing Domain.
public enum SimulatorTargetConfiguration {
    public static let current = SimulatorTarget(
        name: "iPhone 17",
        osVersion: "iOS 26.5",
        udid: "0F0D6B41-9DCA-4D12-A077-F3543AA154F9",
        bundleID: "com.apple.mobilesafari",
        previewBundleID: FixtureScenarioCatalog.bundleID
    )
}
