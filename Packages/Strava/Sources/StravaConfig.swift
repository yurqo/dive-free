import Foundation

public enum StravaConfig {
    public static let clientID = "257138"
    public static let redirectURI = "divefree://strava-callback"
    /// URL scheme portion of `redirectURI`, used to drive ASWebAuthenticationSession.
    public static let callbackScheme = "divefree"
    public static let authURL = URL(string: "https://www.strava.com/oauth/mobile/authorize")!

    /// Base URL of the DiveFree token proxy (a Cloudflare Worker, see `/Server`).
    /// The app POSTs the auth `code` / `refresh_token` here instead of hitting
    /// Strava directly, so the `client_secret` never ships in the binary. This is
    /// a public, non-secret host — safe to hardcode. Point it at your deployed
    /// Worker's custom domain.
    public static let proxyBaseURL = URL(string: "https://strava.divefree.software-engineer.ing")!
}
