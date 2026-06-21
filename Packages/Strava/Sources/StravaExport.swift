import Foundation
import Domain

/// Exports a completed session to Strava: fetches a valid access token, then
/// either uploads a GPX **file** (when the session has a position + time-series
/// data, so heart rate / temperature / depth / track ride along) or falls back
/// to a manual activity create (just the text summary). On a 401 it forces a
/// token refresh and retries once. Rate-limit (429) and other failures surface
/// as `StravaError` for the UI.
@MainActor
public enum StravaExport {
    public static func export(
        _ session: DiveSession,
        auth: StravaAuthManager,
        uploader: StravaUploading
    ) async throws {
        let token = try await auth.validAccessToken()
        let activity = StravaActivity(session: session)
        if let gpx = StravaGPX.build(session) {
            let upload = StravaUpload(
                data: gpx,
                name: activity.name,
                description: activity.description,
                externalID: session.id.uuidString,
                sportType: activity.type
            )
            try await attempt(auth: auth, token: token) { _ = try await uploader.uploadFile(upload, accessToken: $0) }
        } else {
            try await attempt(auth: auth, token: token) { try await uploader.createActivity(activity, accessToken: $0) }
        }
    }

    /// Runs an upload operation with the given token; on a 401 (`.unauthorized`)
    /// refreshes the token and retries exactly once.
    private static func attempt(
        auth: StravaAuthManager,
        token: String,
        _ operation: @Sendable (String) async throws -> Void
    ) async throws {
        do {
            try await operation(token)
        } catch StravaError.unauthorized {
            // Token rejected despite looking valid — refresh and retry once.
            let refreshed = try await auth.refreshedAccessToken()
            try await operation(refreshed)
        }
    }
}
