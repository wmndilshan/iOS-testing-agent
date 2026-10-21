import Foundation

/// Host-level presentation service. It can reveal Simulator.app, but cannot boot a device, launch
/// an application under test, inject input, or execute an arbitrary process.
@MainActor
public protocol SimulatorApplicationOpening {
    func openSimulatorApplication()
}

