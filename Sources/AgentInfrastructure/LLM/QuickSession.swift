import Foundation

/// The session for vision calls that must answer fast: a call that has not answered in 15 s is not going to be quick, and the next model gets
/// the picture. Shared, so the connection to the API is reused between the judge and `look` instead of a new handshake for each.
public enum QuickSession {
    public static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()
}
