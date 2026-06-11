import Foundation

public enum StravaConfig {
    public static let clientID = "257138"
    // Client secret is injected at build time via STRAVA_CLIENT_SECRET
    // environment variable — never hardcoded here.
    public static let redirectURI = "divefree://strava-callback"
    /// URL scheme portion of `redirectURI`, used to drive ASWebAuthenticationSession.
    public static let callbackScheme = "divefree"
    public static let authURL = URL(string: "https://www.strava.com/oauth/mobile/authorize")!
    public static let tokenURL = URL(string: "https://www.strava.com/oauth/token")!

    /// Client secret, injected at build time into the app's Info.plist from the
    /// `STRAVA_CLIENT_SECRET` environment variable — never committed. Falls back
    /// to the process environment for local development. Empty if unconfigured.
    public static var clientSecret: String {
        if let fromPlist = Bundle.main.object(forInfoDictionaryKey: "STRAVA_CLIENT_SECRET") as? String,
           !fromPlist.isEmpty {
            return fromPlist
        }
        return ProcessInfo.processInfo.environment["STRAVA_CLIENT_SECRET"] ?? ""
    }
}
