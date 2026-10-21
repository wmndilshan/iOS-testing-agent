import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// A stand-in for the `idb` command: prints a fixed accessibility tree for `ui describe-all`, one running app for `list-apps`, and accepts every other command.
private func fakeIDB(tree: String) throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fake-idb-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let script = directory.appendingPathComponent("idb")
    try """
    #!/bin/sh
    if [ "$1" = "ui" ] && [ "$2" = "describe-all" ]; then
    cat <<'JSON'
    \(tree)
    JSON
    fi
    if [ "$1" = "list-apps" ]; then
    echo '{"bundle_id": "com.apple.mobilesafari", "name": "App", "process_state": "Running", "pid": 123}'
    fi
    exit 0
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
}

private func node(_ type: String, label: String? = nil, x: Int, y: Int, w: Int, h: Int) -> String {
    let labelField = label.map { ", \"AXLabel\": \"\($0)\"" } ?? ""
    return "{\"type\": \"\(type)\", \"enabled\": true, \"frame\": {\"x\": \(x), \"y\": \(y), \"width\": \(w), \"height\": \(h)}\(labelField)}"
}

@Suite("idb scroll containers")
struct IDBScrollContainerTests {
    /// The app, then two unlabeled cells of the same role: neither has a label or an identifier to tell them apart.
    private func driver() async throws -> (IDBDriver, Observation) {
        let nodes = [node("Application", label: "App", x: 0, y: 0, w: 402, h: 874),
                     node("Cell", x: 0, y: 120, w: 402, h: 300), node("Cell", x: 0, y: 440, w: 402, h: 300)]
        let tree = "[" + nodes.joined(separator: ",\n") + "]"
        let client = IDBClient(executable: try fakeIDB(tree: tree), udid: "710E5B5D-C7CF-4CC7-8A56-CA363D1565BA")
        let driver = IDBDriver(client: client, simulatorUDID: client.udid, isLiveExecutionEnabled: true)
        return (driver, try await driver.captureObservation(bundleID: "com.apple.mobilesafari"))
    }

    @Test("Scrolling uses a container even when look-alike unlabeled containers exist")
    func scrollIgnoresTwins() async throws {
        let (driver, observation) = try await driver()
        let container = try #require(observation.elements.first { $0.role == "cell" })
        let result = try await driver.scroll(snapshotID: observation.snapshotID, containerID: container.id, direction: .down)
        #expect(result.status == .success)
    }

    @Test("A tap on one of two look-alike unlabeled elements is still refused as ambiguous")
    func tapStillAmbiguous() async throws {
        let (driver, observation) = try await driver()
        let container = try #require(observation.elements.first { $0.role == "cell" })
        await #expect(throws: DriverError.self) { _ = try await driver.tap(snapshotID: observation.snapshotID, elementID: container.id) }
    }
}
