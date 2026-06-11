import Foundation

/// Uploads activities to Strava. Abstracted behind a protocol so the app can
/// inject a stub in previews/tests, and so the export orchestration (refresh +
/// retry) can be tested independently of HTTP.
public protocol StravaUploading: Sendable {
    /// POSTs the activity. Throws `StravaError` on a non-2xx response
    /// (`.unauthorized` for 401, `.rateLimited` for 429).
    func upload(_ activity: StravaActivity, accessToken: String) async throws
}

public enum StravaError: Error, Sendable, Equatable {
    case notAuthenticated
    case unauthorized
    case rateLimited
    case server(status: Int)
}

/// Talks to the Strava REST API using an OAuth access token.
public struct StravaClient: StravaUploading {
    private let baseURL: URL
    private let perform: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public init(
        baseURL: URL = URL(string: "https://www.strava.com/api/v3")!,
        perform: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }
    ) {
        self.baseURL = baseURL
        self.perform = perform
    }

    public func upload(_ activity: StravaActivity, accessToken: String) async throws {
        let (_, response) = try await perform(Self.makeRequest(activity, accessToken: accessToken, baseURL: baseURL))
        guard let http = response as? HTTPURLResponse else { throw StravaError.server(status: -1) }
        switch http.statusCode {
        case 200..<300: return
        case 401:       throw StravaError.unauthorized
        case 429:       throw StravaError.rateLimited
        default:        throw StravaError.server(status: http.statusCode)
        }
    }

    /// Builds the `POST /v3/activities` request (form-encoded, bearer auth).
    static func makeRequest(_ activity: StravaActivity, accessToken: String, baseURL: URL) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("activities"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = FormEncoding.body(activity.formFields)
        return request
    }
}

/// No-op uploader for previews and tests.
public struct StubStravaClient: StravaUploading {
    public init() {}
    public func upload(_ activity: StravaActivity, accessToken: String) async throws {}
}
