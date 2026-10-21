import Foundation

/// A driver that can be switched between simulated and live execution.
///
/// The controller sets this before a dispatch. Drivers without the capability (mocks, fakes) are
/// simply not switched.
public protocol LiveExecutionControllable: DeviceDriver {
    var isLiveExecutionEnabled: Bool { get async }
    func setLiveExecution(enabled: Bool) async
}
