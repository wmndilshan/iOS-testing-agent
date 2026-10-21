import Foundation
import AgentCore

public final class LLMGateway: Sendable {
    public let transport: LLMNetworkTransportProtocol
    public let backoffPolicy: BackoffPolicy
    public let clock: ClockProtocol
    /// Invoked once per transport-level retry (never for the first attempt). Purely
    /// observational: it feeds usage accounting and can neither cancel nor extend retries.
    public let retryObserver: (@Sendable (LLMNetworkError) -> Void)?
    /// The single owner of network logging. `LLMClient` and the UI must not log transport events.
    public let logger: any AppLogger
    public let provider: String

    public init(
        transport: LLMNetworkTransportProtocol = URLSessionTransport(),
        backoffPolicy: BackoffPolicy = BackoffPolicy(),
        clock: ClockProtocol = SystemClock(),
        retryObserver: (@Sendable (LLMNetworkError) -> Void)? = nil,
        logger: any AppLogger = NullLogger(),
        provider: String = "llm"
    ) {
        self.transport = transport
        self.backoffPolicy = backoffPolicy
        self.clock = clock
        self.retryObserver = retryObserver
        self.logger = logger
        self.provider = provider
    }

    /// Executes an HTTP request with error classification, exponential backoff, and Retry-After handling.
    ///
    /// Emits `llm.network.request.started|completed|retry|failed`. Only identifiers, sizes, status,
    /// latency and a neutral failure class are logged: never headers, bodies or the full URL.
    public func execute(request: URLRequest) async throws -> Data {
        let requestID = UUID().uuidString
        let context = LogContext(requestID: requestID)
        let started = clock.now()
        let endpoint = Self.endpointID(request)
        logger.info(.llmNetwork, "llm.network.request.started", context: context, fields: [
            "provider": .string(provider), "endpoint": .string(endpoint), "payloadBytes": .int(request.httpBody?.count ?? 0),
        ])
        do {
            let data = try await run(request: request, requestID: requestID)
            logger.info(.llmNetwork, "llm.network.request.completed", context: context,
                        fields: ["provider": .string(provider), "responseBytes": .int(data.count)],
                        duration: clock.now().timeIntervalSince(started))
            return data
        } catch {
            let kind = LLMFailureKind.classify(error)
            logger.error(.llmNetwork, "llm.network.request.failed", context: context,
                         fields: ["provider": .string(provider), "endpoint": .string(endpoint)],
                         duration: clock.now().timeIntervalSince(started), errorClass: kind.rawValue)
            throw error
        }
    }

    /// Identifies the endpoint without its query string (which can carry secrets).
    static func endpointID(_ request: URLRequest) -> String {
        guard let url = request.url else { return "unknown" }
        return "\(url.host ?? "unknown")\(url.path)"
    }

    private func noteRetry(_ error: LLMNetworkError, attempt: Int, delay: TimeInterval, requestID: String) {
        retryObserver?(error)
        logger.warning(.llmNetwork, "llm.network.request.retry", context: LogContext(requestID: requestID),
                       fields: ["provider": .string(provider), "attempt": .int(attempt), "delaySeconds": .double(delay)],
                       errorClass: LLMFailureKind.classify(error).rawValue)
    }

    private func run(request: URLRequest, requestID: String) async throws -> Data {
        var currentAttempt = 0

        while currentAttempt < backoffPolicy.maxAttempts {
            currentAttempt += 1

            let data: Data
            let httpResponse: HTTPURLResponse

            do {
                (data, httpResponse) = try await transport.send(request: request)
            } catch let netErr as LLMNetworkError {
                if netErr.isRetryable && currentAttempt < backoffPolicy.maxAttempts {
                    let sleepSecs = backoffPolicy.delay(forAttempt: currentAttempt)
                    noteRetry(netErr, attempt: currentAttempt, delay: sleepSecs, requestID: requestID)
                    try await clock.sleep(seconds: sleepSecs)
                    continue
                }
                throw netErr
            } catch let urlErr as URLError {
                let classified: LLMNetworkError
                switch urlErr.code {
                case .timedOut:
                    classified = .timeout(urlErr.localizedDescription)
                case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost:
                    classified = .connectionFailure(urlErr.localizedDescription)
                default:
                    classified = .connectionFailure(urlErr.localizedDescription)
                }

                if classified.isRetryable && currentAttempt < backoffPolicy.maxAttempts {
                    let sleepSecs = backoffPolicy.delay(forAttempt: currentAttempt)
                    noteRetry(classified, attempt: currentAttempt, delay: sleepSecs, requestID: requestID)
                    try await clock.sleep(seconds: sleepSecs)
                    continue
                }
                throw classified
            } catch {
                let classified = LLMNetworkError.connectionFailure(error.localizedDescription)
                if currentAttempt < backoffPolicy.maxAttempts {
                    let sleepSecs = backoffPolicy.delay(forAttempt: currentAttempt)
                    noteRetry(classified, attempt: currentAttempt, delay: sleepSecs, requestID: requestID)
                    try await clock.sleep(seconds: sleepSecs)
                    continue
                }
                throw classified
            }

            let status = httpResponse.statusCode

            // 2xx Success
            if (200...299).contains(status) {
                return data
            }

            // Extract error body text
            let responseText = String(data: data, encoding: .utf8) ?? ""

            // Classification
            switch status {
            case 400:
                throw LLMNetworkError.badRequest(statusCode: status, message: responseText)
            case 401:
                throw LLMNetworkError.unauthorized(statusCode: status, message: responseText)
            case 403:
                throw LLMNetworkError.forbidden(statusCode: status, message: responseText)
            case 404:
                throw LLMNetworkError.notFound(statusCode: status, message: responseText)
            case 429:
                let retryAfterSeconds = parseRetryAfter(from: httpResponse)
                let classified = LLMNetworkError.rateLimited(statusCode: status, retryAfter: retryAfterSeconds, message: responseText)
                if currentAttempt < backoffPolicy.maxAttempts {
                    let delay = backoffPolicy.delay(forAttempt: currentAttempt, retryAfter: retryAfterSeconds)
                    noteRetry(classified, attempt: currentAttempt, delay: delay, requestID: requestID)
                    try await clock.sleep(seconds: delay)
                    continue
                }
                throw classified
            case 500, 502, 503, 504:
                let classified = LLMNetworkError.serverError(statusCode: status, message: responseText)
                if currentAttempt < backoffPolicy.maxAttempts {
                    let delay = backoffPolicy.delay(forAttempt: currentAttempt)
                    noteRetry(classified, attempt: currentAttempt, delay: delay, requestID: requestID)
                    try await clock.sleep(seconds: delay)
                    continue
                }
                throw classified
            default:
                let classified = LLMNetworkError.other(statusCode: status, message: responseText)
                if classified.isRetryable && currentAttempt < backoffPolicy.maxAttempts {
                    let delay = backoffPolicy.delay(forAttempt: currentAttempt)
                    noteRetry(classified, attempt: currentAttempt, delay: delay, requestID: requestID)
                    try await clock.sleep(seconds: delay)
                    continue
                }
                throw classified
            }
        }

        throw LLMNetworkError.serverError(statusCode: 504, message: "Max network attempts exceeded.")
    }

    private func parseRetryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let headerValue = response.value(forHTTPHeaderField: "Retry-After") ?? response.value(forHTTPHeaderField: "retry-after") else {
            return nil
        }
        if let seconds = TimeInterval(headerValue.trimmingCharacters(in: .whitespaces)) {
            return seconds
        }
        // Check if header is HTTP Date
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: headerValue) {
            let interval = date.timeIntervalSince(clock.now())
            return max(0, interval)
        }
        return nil
    }
}
