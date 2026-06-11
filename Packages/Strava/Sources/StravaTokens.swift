import Foundation

/// OAuth tokens for a connected Strava account. Persisted in the Keychain.
public struct StravaTokens: Sendable, Equatable, Codable {
    public var accessToken: String
    public var refreshToken: String
    /// Absolute expiry of the access token.
    public var expiresAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    /// Whether the access token is expired (or about to be), accounting for a
    /// small leeway so a token isn't used right as it lapses mid-request.
    public func isExpired(now: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        now >= expiresAt.addingTimeInterval(-leeway)
    }
}

/// Raw token payload returned by Strava's `/oauth/token` endpoint.
public struct StravaTokenResponse: Sendable, Equatable, Codable {
    public let accessToken: String
    public let refreshToken: String
    /// Epoch seconds at which the access token expires.
    public let expiresAt: TimeInterval

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
    }

    /// Maps the API response into stored tokens.
    public var tokens: StravaTokens {
        StravaTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date(timeIntervalSince1970: expiresAt)
        )
    }
}
