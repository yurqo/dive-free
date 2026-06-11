import Foundation
import Testing
import Domain
@testable import Strava

@Suite("Strava")
struct StravaTests {
    @Test("maps a session into an activity with elapsed time and summary")
    func mapsSessionToActivity() {
        let session = DiveSession(
            startTime: Date(timeIntervalSince1970: 0),
            endTime: Date(timeIntervalSince1970: 1800),
            dives: [
                Dive(startTime: Date(timeIntervalSince1970: 10), endTime: Date(timeIntervalSince1970: 40), maxDepthMeters: 14.2)
            ]
        )

        let activity = StravaActivity(session: session)
        #expect(activity.elapsedSeconds == 1800)
        #expect(activity.description?.contains("1 dives") == true)
        #expect(activity.description?.contains("14.2") == true)
    }

    @Test("uploading without a token throws notAuthenticated")
    func requiresToken() async {
        let client = StravaClient(accessToken: nil)
        await #expect(throws: StravaError.self) {
            try await client.upload(StravaActivity(name: "x", startDate: Date(), elapsedSeconds: 0))
        }
    }
}

@Suite("Strava OAuth")
struct StravaOAuthTests {
    @Test("isExpired honours leeway around the expiry instant")
    func tokenExpiry() {
        let now = Date(timeIntervalSince1970: 1_000)
        let fresh = StravaTokens(accessToken: "a", refreshToken: "r", expiresAt: now.addingTimeInterval(3600))
        let lapsing = StravaTokens(accessToken: "a", refreshToken: "r", expiresAt: now.addingTimeInterval(30))
        let stale = StravaTokens(accessToken: "a", refreshToken: "r", expiresAt: now.addingTimeInterval(-1))

        #expect(fresh.isExpired(now: now) == false)
        #expect(lapsing.isExpired(now: now) == true)   // within 60s leeway
        #expect(stale.isExpired(now: now) == true)
    }

    @Test("decodes a Strava token response into stored tokens")
    func decodesTokenResponse() throws {
        let json = Data("""
        {"access_token":"AT","refresh_token":"RT","expires_at":1700000000,"expires_in":21600,"token_type":"Bearer"}
        """.utf8)
        let tokens = try JSONDecoder().decode(StravaTokenResponse.self, from: json).tokens
        #expect(tokens.accessToken == "AT")
        #expect(tokens.refreshToken == "RT")
        #expect(tokens.expiresAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("authorization URL carries the required OAuth parameters")
    func authorizationURLParameters() {
        let url = StravaOAuth.authorizationURL(
            clientID: "123",
            redirectURI: "divefree://strava-callback",
            scope: "activity:write,read",
            state: "xyz"
        )
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        #expect(value("client_id") == "123")
        #expect(value("redirect_uri") == "divefree://strava-callback")
        #expect(value("response_type") == "code")
        #expect(value("scope") == "activity:write,read")
        #expect(value("state") == "xyz")
    }

    @Test("extracts the authorization code from a valid callback")
    func parsesCallbackCode() throws {
        let url = URL(string: "divefree://strava-callback?state=s1&code=abc123&scope=read")!
        #expect(try StravaOAuth.authorizationCode(from: url, expectedState: "s1") == "abc123")
    }

    @Test("rejects a callback whose state does not match")
    func rejectsStateMismatch() {
        let url = URL(string: "divefree://strava-callback?state=other&code=abc")!
        #expect(throws: StravaOAuth.CallbackError.stateMismatch) {
            try StravaOAuth.authorizationCode(from: url, expectedState: "s1")
        }
    }

    @Test("surfaces an access-denied callback")
    func surfacesDenial() {
        let url = URL(string: "divefree://strava-callback?state=s1&error=access_denied")!
        #expect(throws: StravaOAuth.CallbackError.denied("access_denied")) {
            try StravaOAuth.authorizationCode(from: url, expectedState: "s1")
        }
    }

    @Test("throws when the callback has no code")
    func missingCode() {
        let url = URL(string: "divefree://strava-callback?state=s1")!
        #expect(throws: StravaOAuth.CallbackError.missingCode) {
            try StravaOAuth.authorizationCode(from: url, expectedState: "s1")
        }
    }

    @Test("token exchange request posts the code and authorization_code grant")
    func tokenExchangeBody() {
        let request = StravaOAuth.tokenExchangeRequest(code: "C", clientID: "123", clientSecret: "secret")
        #expect(request.httpMethod == "POST")
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("code=C"))
        #expect(body.contains("grant_type=authorization_code"))
        #expect(body.contains("client_secret=secret"))
    }

    @Test("refresh request posts the refresh token and refresh_token grant")
    func refreshBody() {
        let request = StravaOAuth.refreshRequest(refreshToken: "RT", clientID: "123", clientSecret: "secret")
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("refresh_token=RT"))
        #expect(body.contains("grant_type=refresh_token"))
    }

    @Test("in-memory token store saves, loads, and clears")
    func inMemoryStore() throws {
        let store = InMemoryTokenStore()
        #expect(store.load() == nil)
        let tokens = StravaTokens(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSince1970: 0))
        try store.save(tokens)
        #expect(store.load() == tokens)
        try store.clear()
        #expect(store.load() == nil)
    }
}

// MARK: - Auth manager flow

/// Returns a canned callback URL, capturing the requested auth URL.
private final class StubWebAuth: WebAuthenticating, @unchecked Sendable {
    let callback: URL
    init(callback: URL) { self.callback = callback }
    func authenticate(url: URL, callbackScheme: String) async throws -> URL { callback }
}

private func tokenResponse(accessToken: String, expiresAt: TimeInterval) -> (URLRequest) async throws -> (Data, URLResponse) {
    { request in
        let json = Data("""
        {"access_token":"\(accessToken)","refresh_token":"RT","expires_at":\(Int(expiresAt))}
        """.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (json, response)
    }
}

@Suite("StravaAuthManager")
@MainActor
struct StravaAuthManagerTests {
    @Test("connect runs the flow, stores tokens, and reports connected")
    func connectStoresTokens() async throws {
        let store = InMemoryTokenStore()
        let manager = StravaAuthManager(
            store: store,
            webAuth: StubWebAuth(callback: URL(string: "divefree://strava-callback?state=S&code=C")!),
            clientSecret: "secret",
            perform: tokenResponse(accessToken: "AT", expiresAt: 9_999_999_999),
            makeState: { "S" }
        )
        #expect(manager.isConnected == false)

        try await manager.connect()

        #expect(manager.isConnected == true)
        #expect(store.load()?.accessToken == "AT")
    }

    @Test("connect surfaces a denied authorization")
    func connectPropagatesDenial() async {
        let manager = StravaAuthManager(
            store: InMemoryTokenStore(),
            webAuth: StubWebAuth(callback: URL(string: "divefree://strava-callback?state=S&error=access_denied")!),
            clientSecret: "secret",
            perform: tokenResponse(accessToken: "AT", expiresAt: 0),
            makeState: { "S" }
        )
        await #expect(throws: StravaOAuth.CallbackError.self) {
            try await manager.connect()
        }
        #expect(manager.isConnected == false)
    }

    @Test("disconnect clears stored tokens")
    func disconnectClears() throws {
        let store = InMemoryTokenStore(
            tokens: StravaTokens(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSince1970: 0))
        )
        let manager = StravaAuthManager(store: store, webAuth: StubWebAuth(callback: URL(string: "x://y")!))
        #expect(manager.isConnected == true)
        manager.disconnect()
        #expect(manager.isConnected == false)
        #expect(store.load() == nil)
    }

    @Test("validAccessToken returns the stored token while it is fresh")
    func validTokenWhenFresh() async throws {
        let store = InMemoryTokenStore(
            tokens: StravaTokens(accessToken: "FRESH", refreshToken: "r", expiresAt: Date().addingTimeInterval(3600))
        )
        let manager = StravaAuthManager(
            store: store,
            webAuth: StubWebAuth(callback: URL(string: "x://y")!),
            clientSecret: "secret",
            perform: { _ in Issue.record("should not refresh"); throw StravaError.notAuthenticated }
        )
        #expect(try await manager.validAccessToken() == "FRESH")
    }

    @Test("validAccessToken refreshes an expired token")
    func refreshesExpiredToken() async throws {
        let store = InMemoryTokenStore(
            tokens: StravaTokens(accessToken: "OLD", refreshToken: "RT", expiresAt: Date().addingTimeInterval(-10))
        )
        let manager = StravaAuthManager(
            store: store,
            webAuth: StubWebAuth(callback: URL(string: "x://y")!),
            clientSecret: "secret",
            perform: tokenResponse(accessToken: "NEW", expiresAt: Date().addingTimeInterval(3600).timeIntervalSince1970)
        )
        #expect(try await manager.validAccessToken() == "NEW")
        #expect(store.load()?.accessToken == "NEW")
    }

    @Test("validAccessToken throws when not connected")
    func throwsWhenDisconnected() async {
        let manager = StravaAuthManager(
            store: InMemoryTokenStore(),
            webAuth: StubWebAuth(callback: URL(string: "x://y")!)
        )
        await #expect(throws: StravaError.self) {
            _ = try await manager.validAccessToken()
        }
    }
}
