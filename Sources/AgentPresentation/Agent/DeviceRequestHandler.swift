import Foundation
import AgentCore

/// What became of one device request from the agents. Written back to them as a `device-result`.
public struct DeviceReply: Sendable, Equatable {
    public let ok: Bool
    public let text: String
    public let file: String?
    public let point: DevicePoint?
}

/// A place on the device screen, in device points.
public struct DevicePoint: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// One command that ran, for the highlight and for saving a session as a test case.
public struct DeviceExecution: Sendable, Equatable {
    public let command: DeviceCommand
    public let phrase: String
    /// What the command reported, for example “Tapped “Search” at (200, 90).”
    public let resultText: String
    public let ok: Bool
    public let point: DevicePoint?
    /// True when the person did it themselves (a take-over tap), false when an agent asked.
    public let byPerson: Bool
}

/// The one place a device request is checked, asked about, run and answered. The chat and the Operate section share it, so the approval
/// rules are the same everywhere: read-only runs, reversible asks once (or once per grant), destructive always asks.
@MainActor
public final class DeviceRequestHandler {
    let control: (any DeviceControlling)?
    private let projectRoot: URL
    /// The read-only repository, when one is set up, so the validator knows where host files may be read from.
    var repository: () -> URL? = { nil }
    var onApproval: (DeviceApproval?) -> Void = { _ in }
    var onTarget: (DeviceTarget?) -> Void = { _ in }
    var onExecuted: (DeviceExecution) -> Void = { _ in }

    private(set) var grants = DeviceGrants()
    private(set) var target: DeviceTarget?
    private(set) var approval: DeviceApproval? { didSet { onApproval(approval) } }
    private var pending: CheckedContinuation<DeviceAnswer, Never>?

    public init(control: (any DeviceControlling)?, projectRoot: URL) {
        self.control = control
        self.projectRoot = projectRoot
    }

    public var isAvailable: Bool { control != nil }

    /// A new conversation or task starts from nothing granted.
    public func resetGrants() { grants = DeviceGrants() }

    /// Allows reversible commands without asking, for the current chat or task.
    public func allowReversible() { grants.allowsReversible = true }

    public func setTarget(_ value: DeviceTarget?) {
        target = value
        onTarget(value)
    }

    /// Decodes a request event and handles it.
    public func handle(_ event: [String: Any]) async -> DeviceReply {
        guard let raw = event["command"], JSONSerialization.isValidJSONObject(raw), let data = try? JSONSerialization.data(withJSONObject: raw),
              let command = try? JSONDecoder().decode(DeviceCommand.self, from: data) else {
            return DeviceReply(ok: false, text: "The device request could not be read.", file: nil, point: nil)
        }
        return await process(command, id: event["id"] as? String ?? UUID().uuidString)
    }

    func process(_ command: DeviceCommand, id: String) async -> DeviceReply {
        guard let pipeline = makePipeline() else { return Self.unavailable }
        let prepared: DeviceCommandPipeline.Prepared
        do { prepared = try pipeline.prepare(command) } catch { return DeviceReply(ok: false, text: error.localizedDescription, file: nil, point: nil) }
        if case .ask(let offerGrant) = DeviceControlPolicy.decision(for: prepared.risk, grants: grants) {
            guard approval == nil else {
                return DeviceReply(ok: false, text: "Another device command is waiting for the person. Wait for it before sending the next one.", file: nil, point: nil)
            }
            approval = DeviceApproval(id: id, phrase: prepared.phrase, risk: prepared.risk, offersChatGrant: offerGrant)
            let answer = await withCheckedContinuation { pending = $0 }
            approval = nil
            switch answer {
            case .deny: return DeviceReply(ok: false, text: DeviceControlError.denied.localizedDescription, file: nil, point: nil)
            case .allowForChat: if offerGrant { grants.allowsReversible = true }
            case .approveOnce: break
            }
        }
        return await execute(prepared, with: pipeline, byPerson: false)
    }

    /// A person's own command (a take-over tap): validated and run, never asked about.
    public func runAsPerson(_ command: DeviceCommand) async -> DeviceReply {
        guard let pipeline = makePipeline() else { return Self.unavailable }
        do { return await execute(try pipeline.prepare(command), with: pipeline, byPerson: true) }
        catch { return DeviceReply(ok: false, text: error.localizedDescription, file: nil, point: nil) }
    }

    private static let unavailable = DeviceReply(ok: false, text: "Device control is not available: idb was not found (see the README).", file: nil, point: nil)

    private func makePipeline() -> DeviceCommandPipeline? {
        control.map { DeviceCommandPipeline(control: $0, context: DeviceValidationContext(projectRoot: projectRoot, repository: repository())) }
    }

    private func execute(_ prepared: DeviceCommandPipeline.Prepared, with pipeline: DeviceCommandPipeline, byPerson: Bool) async -> DeviceReply {
        do {
            let (result, used) = try await pipeline.run(prepared, remembered: target)
            if target == nil { setTarget(used) }
            let point = result.pointX.flatMap { x in result.pointY.map { DevicePoint(x: x, y: $0) } }
            if prepared.risk != .readOnly {
                onExecuted(DeviceExecution(command: prepared.command, phrase: prepared.phrase, resultText: result.text, ok: result.ok, point: point, byPerson: byPerson))
            }
            return DeviceReply(ok: result.ok, text: result.text, file: result.filePath, point: point)
        } catch {
            return DeviceReply(ok: false, text: error.localizedDescription, file: nil, point: nil)
        }
    }

    /// The person's answer to the banner. With no question open it does nothing.
    public func answer(_ answer: DeviceAnswer) {
        guard let pending else { return }
        self.pending = nil
        pending.resume(returning: answer)
    }
}
