import Foundation

public protocol HTTPClient: Sendable {
    func get(_ url: URL, headers: [String: String]) async throws -> (status: Int, body: Data)
}

public struct URLSessionHTTPClient: HTTPClient {
    public init() {}

    public func get(_ url: URL, headers: [String: String]) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: url, timeoutInterval: 15)
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

public enum UsageError: Error, Equatable {
    case http(Int)
    case badResponse
}

/// Calls the (undocumented) endpoint Claude Code uses for `/usage`. Read-only; never refreshes tokens.
public struct UsageClient: Sendable {
    public static let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    let http: HTTPClient

    public init(http: HTTPClient = URLSessionHTTPClient()) { self.http = http }

    public func fetch(accessToken: String) async throws -> AccountUsage {
        let (status, body) = try await http.get(Self.url, headers: [
            "Authorization": "Bearer \(accessToken)",
            "anthropic-beta": "oauth-2025-04-20",
            "Accept": "application/json",
        ])
        guard status == 200 else { throw UsageError.http(status) }
        guard let usage = try? UsageParser.parse(body, fetchedAt: Date()) else { throw UsageError.badResponse }
        return usage
    }
}
