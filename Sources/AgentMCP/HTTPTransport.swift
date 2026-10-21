import Foundation
import Network
import AgentGateway

/// One HTTP request, as far as the MCP endpoint needs it.
struct HTTPRequest: Equatable {
    var method: String
    var path: String
    var headers: [String: String]   // names lower-cased
    var body: Data
}

struct HTTPResponse: Equatable {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()

    static func text(_ status: Int, _ message: String) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["content-type": "text/plain; charset=utf-8"], body: Data(message.utf8))
    }

    var serialized: Data {
        let reasons = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 413: "Payload Too Large"]
        var head = "HTTP/1.1 \(status) \(reasons[status] ?? "Status")\r\ncontent-length: \(body.count)\r\nconnection: close\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        return Data((head + "\r\n").utf8) + body
    }
}

/// Reads a request from bytes as they arrive.
enum HTTPRequestParser {
    enum Result: Equatable { case needMore, tooLarge, malformed, request(HTTPRequest) }

    /// The most a request body may be: a JSON-RPC message, not an upload.
    static let maxBody = 1_000_000

    static func parse(_ data: Data) -> Result {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return data.count > 16_000 ? .malformed : .needMore }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return .malformed }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ").map(String.init)
        guard first.count == 3 else { return .malformed }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .malformed }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = headers["content-length"].flatMap(Int.init) ?? 0
        guard length >= 0, length <= maxBody else { return .tooLarge }
        let body = data[end.upperBound...]
        guard body.count >= length else { return .needMore }
        return .request(HTTPRequest(method: first[0], path: first[1], headers: headers, body: Data(body.prefix(length))))
    }
}

/// The MCP endpoint over HTTP ("streamable HTTP", answering each POST with one JSON body). It listens on the loopback address only and needs a
/// bearer token on every request, and refuses a browser's cross-site request (an `Origin` that is not this machine), so a web page cannot drive
/// the simulator through it.
public struct HTTPEndpoint: Sendable {
    let gateway: Gateway
    let info: MCPServerInfo
    let token: String
    /// How long a call may take before the client gets an error: a case run is minutes.
    let timeout: TimeInterval

    public init(gateway: Gateway, info: MCPServerInfo, token: String, timeout: TimeInterval = 1800) {
        self.gateway = gateway
        self.info = info
        self.token = token
        self.timeout = timeout
    }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        guard request.path == "/mcp" else { return .text(404, "The endpoint is /mcp.") }
        if let origin = request.headers["origin"], !Self.isLocal(origin) { return .text(403, "Cross-site requests are refused.") }
        guard Self.constantTimeEqual(request.headers["authorization"] ?? "", "Bearer " + token) else {
            var response = HTTPResponse.text(401, "A bearer token is required.")
            response.headers["www-authenticate"] = "Bearer"
            return response
        }
        guard request.method == "POST" else {
            var response = HTTPResponse.text(405, "Use POST.")
            response.headers["allow"] = "POST"
            return response
        }
        guard let object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] else { return .text(400, "The body must be one JSON-RPC message.") }
        let replies = Replies()
        let server = MCPServer(gateway: gateway, info: info) { replies.add($0) }
        await server.receive(request.body)
        // A notification or a response needs no answer.
        guard let id = object["id"], object["method"] != nil else { return HTTPResponse(status: 202) }
        guard let data = await replies.wait(forID: id, timeout: timeout) else { return .text(400, "The call did not finish in time.") }
        return HTTPResponse(status: 200, headers: ["content-type": "application/json"], body: data)
    }

    static func isLocal(_ origin: String) -> Bool {
        guard let host = URL(string: origin)?.host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1"].contains(host)
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var difference = x.count ^ y.count
        for index in 0..<min(x.count, y.count) { difference |= Int(x[index] ^ y[index]) }
        return difference == 0
    }
}

/// Collects what one server sends and hands back the reply with a given id (progress notifications have none and are not part of a JSON reply).
private final class Replies: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [(id: AnyHashable?, data: Data)] = []

    func add(_ data: Data) {
        let id = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["id"] as? AnyHashable
        lock.withLock { messages.append((id, data)) }
    }

    func wait(forID id: Any, timeout: TimeInterval) async -> Data? {
        let wanted = id as? AnyHashable
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let found = lock.withLock({ messages.first { $0.id != nil && $0.id == wanted } }) { return found.data }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }
}

/// Listens on 127.0.0.1 and gives each connection's request to the endpoint.
public enum HTTPTransport {
    public static func run(endpoint: HTTPEndpoint, port: UInt16) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? 0)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in serve(connection, endpoint) }
        listener.start(queue: .global())
        // Runs until the process is stopped.
        while true { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
    }

    private static func serve(_ connection: NWConnection, _ endpoint: HTTPEndpoint) {
        connection.start(queue: .global())
        @Sendable func read(_ buffer: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                var buffer = buffer
                if let data { buffer.append(data) }
                switch HTTPRequestParser.parse(buffer) {
                case .needMore:
                    if error != nil || isComplete { connection.cancel() } else { read(buffer) }
                case .tooLarge: reply(.text(413, "Too large."), on: connection)
                case .malformed: reply(.text(400, "Malformed request."), on: connection)
                case .request(let request):
                    Task { reply(await endpoint.handle(request), on: connection) }
                }
            }
        }
        read(Data())
    }

    private static func reply(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized, completion: .contentProcessed { _ in connection.cancel() })
    }
}
