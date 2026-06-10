import Foundation

/// Uploads activities to Strava. Abstracted behind a protocol so the app can
/// inject a stub in previews/tests.
public protocol StravaUploading: Sendable {
    func upload(_ activity: StravaActivity) async throws
}

public enum StravaError: Error, Sendable {
    case notAuthenticated
    case server(status: Int)
}

/// Talks to the Strava REST API using an OAuth access token.
/// Networking is stubbed for now (Phase 7); the shape is ready for wiring.
public struct StravaClient: StravaUploading {
    private let accessToken: String?
    private let session: URLSession
    private let baseURL = URL(string: "https://www.strava.com/api/v3")!

    public init(accessToken: String? = nil, session: URLSession = .shared) {
        self.accessToken = accessToken
        self.session = session
    }

    public func upload(_ activity: StravaActivity) async throws {
        guard accessToken != nil else { throw StravaError.notAuthenticated }
        // TODO(Phase 7): POST to /activities with the OAuth bearer token.
    }
}

/// No-op uploader for previews and tests.
public struct StubStravaClient: StravaUploading {
    public init() {}
    public func upload(_ activity: StravaActivity) async throws {}
}
