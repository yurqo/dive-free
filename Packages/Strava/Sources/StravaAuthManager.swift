import Foundation
import Observation

/// Drives the Strava connection: runs the OAuth flow, stores tokens in the
/// Keychain, refreshes them on expiry, and publishes connected state for the UI.
///
/// The browser and network are injected (`WebAuthenticating`, `perform`) so the
/// whole flow is testable with stubs. `@MainActor` because it owns observable UI
/// state and an `ASWebAuthenticationSession`, both main-actor bound.
@MainActor
@Observable
public final class StravaAuthManager {
    public private(set) var isConnected: Bool

    private let store: StravaTokenStore
    private let webAuth: WebAuthenticating
    private let clientSecret: String
    private let perform: (URLRequest) async throws -> (Data, URLResponse)
    private let makeState: () -> String

    public init(
        store: StravaTokenStore,
        webAuth: WebAuthenticating,
        clientSecret: String = StravaConfig.clientSecret,
        perform: @escaping (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) },
        makeState: @escaping () -> String = { UUID().uuidString }
    ) {
        self.store = store
        self.webAuth = webAuth
        self.clientSecret = clientSecret
        self.perform = perform
        self.makeState = makeState
        self.isConnected = store.load() != nil
    }

    /// Runs the full authorization-code flow and stores the resulting tokens.
    public func connect() async throws {
        let state = makeState()
        let authURL = StravaOAuth.authorizationURL(state: state)
        let callback = try await webAuth.authenticate(url: authURL, callbackScheme: StravaConfig.callbackScheme)
        let code = try StravaOAuth.authorizationCode(from: callback, expectedState: state)
        let request = StravaOAuth.tokenExchangeRequest(code: code, clientSecret: clientSecret)
        let tokens = try await exchangeTokens(request)
        try store.save(tokens)
        isConnected = true
    }

    /// Clears stored tokens and marks the account disconnected.
    public func disconnect() {
        try? store.clear()
        isConnected = false
    }

    /// Returns a currently-valid access token, transparently refreshing an
    /// expired one. Throws `notAuthenticated` if the account isn't connected.
    public func validAccessToken() async throws -> String {
        guard let tokens = store.load() else {
            isConnected = false
            throw StravaError.notAuthenticated
        }
        guard tokens.isExpired() else { return tokens.accessToken }

        let request = StravaOAuth.refreshRequest(refreshToken: tokens.refreshToken, clientSecret: clientSecret)
        let refreshed = try await exchangeTokens(request)
        try store.save(refreshed)
        isConnected = true
        return refreshed.accessToken
    }

    /// Forces a token refresh regardless of the local expiry clock — used to
    /// recover from a 401 (e.g. a server-side revocation or clock skew).
    public func refreshedAccessToken() async throws -> String {
        guard let tokens = store.load() else {
            isConnected = false
            throw StravaError.notAuthenticated
        }
        let request = StravaOAuth.refreshRequest(refreshToken: tokens.refreshToken, clientSecret: clientSecret)
        let refreshed = try await exchangeTokens(request)
        try store.save(refreshed)
        isConnected = true
        return refreshed.accessToken
    }

    private func exchangeTokens(_ request: URLRequest) async throws -> StravaTokens {
        let (data, response) = try await perform(request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw StravaError.server(status: http.statusCode)
        }
        return try JSONDecoder().decode(StravaTokenResponse.self, from: data).tokens
    }
}
