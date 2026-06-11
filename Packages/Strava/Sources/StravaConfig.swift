import Foundation

public enum StravaConfig {
    public static let clientID = "257138"
    // Client secret is injected at build time via STRAVA_CLIENT_SECRET
    // environment variable — never hardcoded here.
    public static let redirectURI = "divefree://strava-callback"
    public static let authURL = URL(string: "https://www.strava.com/oauth/mobile/authorize")!
    public static let tokenURL = URL(string: "https://www.strava.com/oauth/token")!
}
