import Foundation

/// One device command on its way to the device: validated against the catalog, then (the caller's business) approved, then run on a target.
/// The app's approval banner and the gateway's confirm rule both use it, so the checks and the target rule are written once.
public struct DeviceCommandPipeline: Sendable {
    public let control: any DeviceControlling
    public let context: DeviceValidationContext

    public init(control: any DeviceControlling, context: DeviceValidationContext) {
        self.control = control
        self.context = context
    }

    /// A command that passed validation, with what the catalog says about it.
    public struct Prepared: Sendable {
        public let command: DeviceCommand
        public let spec: DeviceCommandSpec
        public var risk: DeviceCommandRisk { spec.risk }
        public var phrase: String { DeviceCommandCatalog.phrase(command) }
    }

    /// Checks the command; throws the reason it is refused.
    public func prepare(_ command: DeviceCommand) throws -> Prepared {
        let valid = try DeviceCommandValidator.validate(command, context: context)
        return Prepared(command: valid, spec: DeviceCommandCatalog.spec(for: valid.kind))
    }

    /// Runs a prepared command. The target is the one the command names, else `remembered`, else the booted simulator; the one used is returned so
    /// the caller can remember it.
    public func run(_ prepared: Prepared, remembered: DeviceTarget?) async throws -> (result: DeviceCommandResult, target: DeviceTarget) {
        let target = try await resolveTarget(prepared.command, remembered: remembered)
        return (try await control.run(prepared.command, on: target, context: context), target)
    }

    public func resolveTarget(_ command: DeviceCommand, remembered: DeviceTarget?) async throws -> DeviceTarget {
        if let udid = command.target {
            guard let found = try await control.targets().first(where: { $0.udid == udid }) else {
                throw DeviceControlError.invalid("No target has the id \(udid). Use list_targets.")
            }
            return found
        }
        if let remembered { return remembered }
        guard let booted = await control.defaultTarget() else {
            throw DeviceControlError.invalid("No simulator is booted. Use list_targets to find one, then boot it by giving its id as the target.")
        }
        return booted
    }
}
