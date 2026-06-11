import Foundation
import Domain

/// Exports a completed session to Strava: builds the activity, fetches a valid
/// access token, uploads, and on a 401 forces a token refresh and retries once.
/// Rate-limit (429) and other failures surface as `StravaError` for the UI.
@MainActor
public enum StravaExport {
    public static func export(
        _ session: DiveSession,
        auth: StravaAuthManager,
        uploader: StravaUploading
    ) async throws {
        let activity = StravaActivity(session: session)
        let token = try await auth.validAccessToken()
        do {
            try await uploader.upload(activity, accessToken: token)
        } catch StravaError.unauthorized {
            // Token rejected despite looking valid — refresh and retry once.
            let refreshed = try await auth.refreshedAccessToken()
            try await uploader.upload(activity, accessToken: refreshed)
        }
    }
}
