import Foundation

/// Immutable correlation carried by one Preview interaction. It is a domain value because the
/// application port accepts it without depending on presentation implementation types.
public struct PreviewSessionIdentity: Sendable, Equatable, Hashable {
    public let sessionID: String
    public let generation: UInt64
    public let simulatorUDID: String
    public let xctestTargetUDID: String
    public let targetBundleID: String
    public let executionMode: ExecutionMode
    public let observationSnapshotID: String
    public let framebufferSequence: UInt64
    public let framebufferTimestamp: Date
    public let observationTimestamp: Date

    public init(sessionID: String = UUID().uuidString, generation: UInt64,
                simulatorUDID: String, xctestTargetUDID: String, targetBundleID: String,
                executionMode: ExecutionMode, observationSnapshotID: String,
                framebufferSequence: UInt64, framebufferTimestamp: Date,
                observationTimestamp: Date) {
        self.sessionID = sessionID
        self.generation = generation
        self.simulatorUDID = simulatorUDID
        self.xctestTargetUDID = xctestTargetUDID
        self.targetBundleID = targetBundleID
        self.executionMode = executionMode
        self.observationSnapshotID = observationSnapshotID
        self.framebufferSequence = framebufferSequence
        self.framebufferTimestamp = framebufferTimestamp
        self.observationTimestamp = observationTimestamp
    }
}
