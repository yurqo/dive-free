import Foundation

/// Pure helpers for the Strava OAuth 2.0 authorization-code flow: building the
/// authorization URL, parsing the redirect callback, and building the token
/// exchange / refresh requests. Kept side-effect-free so the whole flow is
/// unit-testable without a browser or network.
public enum StravaOAuth {
    /// Default scope: read profile + write activities (needed to upload dives).
    public static let defaultScope = "activity:write,read"

    /// Authorization URL the user is sent to in the browser.
    public static func authorizationURL(
        clientID: String = StravaConfig.clientID,
        redirectURI: String = StravaConfig.redirectURI,
        scope: String = defaultScope,
        state: String,
        authBase: URL = StravaConfig.authURL
    ) -> URL {
        var components = URLComponents(url: authBase, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "approval_prompt", value: "auto"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    public enum CallbackError: Error, Equatable, Sendable {
        /// The user declined, or Strava returned an `error` parameter.
        case denied(String)
        /// No `code` present in the callback.
        case missingCode
        /// `state` did not match the value we sent (possible CSRF).
        case stateMismatch
    }

    /// Extracts the authorization code from the redirect callback URL, verifying
    /// the `state` round-trips. Throws on denial / malformed callbacks.
    public static func authorizationCode(from callback: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        if let error = value("error") { throw CallbackError.denied(error) }
        guard value("state") == expectedState else { throw CallbackError.stateMismatch }
        guard let code = value("code"), !code.isEmpty else { throw CallbackError.missingCode }
        return code
    }

    /// POST request that exchanges an authorization code for tokens via the
    /// DiveFree token proxy (which adds the `client_id` + `client_secret`).
    public static func tokenExchangeRequest(
        code: String,
        proxyBaseURL: URL = StravaConfig.proxyBaseURL
    ) -> URLRequest {
        jsonRequest(url: proxyBaseURL.appendingPathComponent("token"), fields: ["code": code])
    }

    /// POST request that refreshes an expired access token via the token proxy.
    public static func refreshRequest(
        refreshToken: String,
        proxyBaseURL: URL = StravaConfig.proxyBaseURL
    ) -> URLRequest {
        jsonRequest(url: proxyBaseURL.appendingPathComponent("refresh"), fields: ["refresh_token": refreshToken])
    }

    /// Builds an `application/json` POST request with the given fields.
    private static func jsonRequest(url: URL, fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: fields)
        return request
    }
}
