import Foundation

// Modeled but not implemented. They exist so the typed model is complete and so that, if a descriptor is
// ever added before its implementation, execution fails closed instead of reporting success.

private func unsupported(_ action: String) -> DriverError {
    DriverError.unsupportedCapability("\(action) has no implementation; no action was performed on the simulator.")
}

extension KeyPressAction: IOSPerformable { func perform(in env: IOSExecutionEnvironment) async throws -> IOSActionOutput { throw unsupported("key_press") } }
extension DismissOverlayAction: IOSPerformable { func perform(in env: IOSExecutionEnvironment) async throws -> IOSActionOutput { throw unsupported("dismiss_overlay") } }
extension SelectPickerValueAction: IOSPerformable { func perform(in env: IOSExecutionEnvironment) async throws -> IOSActionOutput { throw unsupported("select_picker_value") } }
extension LaunchAppAction: IOSPerformable { func perform(in env: IOSExecutionEnvironment) async throws -> IOSActionOutput { throw unsupported("launch_app") } }
extension TerminateAppAction: IOSPerformable { func perform(in env: IOSExecutionEnvironment) async throws -> IOSActionOutput { throw unsupported("terminate_app") } }
extension ActivateAppAction: IOSPerformable { func perform(in env: IOSExecutionEnvironment) async throws -> IOSActionOutput { throw unsupported("activate_app") } }
