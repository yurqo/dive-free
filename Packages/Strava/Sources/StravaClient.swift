import Foundation

/// Uploads activities to Strava. Abstracted behind a protocol so the app can
/// inject a stub in previews/tests, and so the export orchestration (refresh +
/// retry) can be tested independently of HTTP.
public protocol StravaUploading: Sendable {
    /// Manually creates an activity from a summary, with no time-series data.
    /// The fallback path when there's no file to upload. Throws `StravaError` on
    /// a non-2xx response (`.unauthorized` for 401, `.rateLimited` for 429).
    func createActivity(_ activity: StravaActivity, accessToken: String) async throws

    /// Uploads an activity file, polls Strava until it finishes processing,
    /// forces the sport type, and returns the new activity id. Throws
    /// `StravaError` (`.uploadFailed` if Strava rejects the file while
    /// processing, `.uploadTimedOut` if it never finishes in the poll budget).
    @discardableResult
    func uploadFile(_ upload: StravaUpload, accessToken: String) async throws -> Int
}

public enum StravaError: Error, Sendable, Equatable {
    case notAuthenticated
    case unauthorized
    case rateLimited
    case server(status: Int)
    /// Strava accepted the file but rejected it while processing — e.g. a
    /// duplicate of an existing activity, or an unparseable file. Carries
    /// Strava's own message so the UI can show it.
    case uploadFailed(String)
    /// The upload didn't finish processing within the poll budget.
    case uploadTimedOut
}

/// Talks to the Strava REST API using an OAuth access token.
public struct StravaClient: StravaUploading {
    private let baseURL: URL
    private let perform: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    /// Delay between upload-status polls.
    private let pollInterval: Duration
    /// Maximum number of status polls before giving up with `.uploadTimedOut`.
    private let maxPollAttempts: Int
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(
        baseURL: URL = URL(string: "https://www.strava.com/api/v3")!,
        perform: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) },
        pollInterval: Duration = .seconds(2),
        maxPollAttempts: Int = 15,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.baseURL = baseURL
        self.perform = perform
        self.pollInterval = pollInterval
        self.maxPollAttempts = max(0, maxPollAttempts)
        self.sleep = sleep
    }

    public func createActivity(_ activity: StravaActivity, accessToken: String) async throws {
        let (_, response) = try await perform(Self.makeActivityRequest(activity, accessToken: accessToken, baseURL: baseURL))
        try Self.checkStatus(response)
    }

    @discardableResult
    public func uploadFile(_ upload: StravaUpload, accessToken: String) async throws -> Int {
        let (data, response) = try await perform(Self.makeUploadRequest(upload, accessToken: accessToken, baseURL: baseURL))
        // A 401 here is safe to refresh-and-retry: the file wasn't accepted, so
        // re-POSTing can't duplicate the activity.
        try Self.checkStatus(response)
        var status = try Self.decodeStatus(data)

        // Strava processes the upload asynchronously: poll until it yields an
        // activity id or rejects the file. Once the POST is accepted the file is
        // committed, so a poll hiccup (network, 401/429/5xx, garbage body) is
        // transient — keep polling within the budget rather than re-POST (which
        // would duplicate the activity) or abort an upload that's still
        // processing server-side.
        for attempt in 0...maxPollAttempts {
            if let error = status.error, !error.isEmpty { throw Self.processingError(error) }
            if let activityID = status.activityID {
                // Best-effort: the activity already exists, so a failed type
                // change shouldn't fail the export.
                try? await setSportType(upload.sportType, activityID: activityID, accessToken: accessToken)
                return activityID
            }
            if attempt == maxPollAttempts { break }
            try await sleep(pollInterval)
            if let polled = await pollStatus(id: status.id, accessToken: accessToken) {
                status = polled
            }
        }
        throw StravaError.uploadTimedOut
    }

    /// Fetches the upload's processing status, returning `nil` on any transient
    /// failure (network error, non-2xx, unparseable body) so the caller keeps
    /// polling instead of aborting a file that's already committed.
    private func pollStatus(id: Int, accessToken: String) async -> StravaUploadStatus? {
        guard let (data, response) = try? await perform(Self.makeUploadStatusRequest(id: id, accessToken: accessToken, baseURL: baseURL)),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let status = try? JSONDecoder().decode(StravaUploadStatus.self, from: data) else {
            return nil
        }
        return status
    }

    private func setSportType(_ sportType: String, activityID: Int, accessToken: String) async throws {
        let (_, response) = try await perform(Self.makeSportTypeRequest(sportType, activityID: activityID, accessToken: accessToken, baseURL: baseURL))
        try Self.checkStatus(response)
    }

    // MARK: - Requests

    /// Builds the `POST /v3/activities` request (form-encoded, bearer auth).
    static func makeActivityRequest(_ activity: StravaActivity, accessToken: String, baseURL: URL) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("activities"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = FormEncoding.body(activity.formFields)
        return request
    }

    /// Builds the `POST /v3/uploads` multipart request carrying the activity file.
    static func makeUploadRequest(_ upload: StravaUpload, accessToken: String, baseURL: URL) -> URLRequest {
        let boundary = "DiveFree-\(UUID().uuidString)"
        var request = URLRequest(url: baseURL.appendingPathComponent("uploads"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = MultipartEncoding.body(
            fields: upload.formFields,
            file: .init(name: "file", filename: "dive.\(upload.dataType)", contentType: "application/gpx+xml", data: upload.data),
            boundary: boundary
        )
        return request
    }

    /// Builds the `GET /v3/uploads/{id}` status-poll request.
    static func makeUploadStatusRequest(id: Int, accessToken: String, baseURL: URL) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("uploads/\(id)"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Builds the `PUT /v3/activities/{id}` request that forces the sport type.
    static func makeSportTypeRequest(_ sportType: String, activityID: Int, accessToken: String, baseURL: URL) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("activities/\(activityID)"))
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = FormEncoding.body(["sport_type": sportType])
        return request
    }

    // MARK: - Responses

    /// Maps an HTTP response to success or a `StravaError`.
    static func checkStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw StravaError.server(status: -1) }
        switch http.statusCode {
        case 200..<300: return
        case 401:       throw StravaError.unauthorized
        case 429:       throw StravaError.rateLimited
        default:        throw StravaError.server(status: http.statusCode)
        }
    }

    /// Maps a Strava processing error to a `StravaError`. A duplicate — the same
    /// session was already uploaded (`external_id` is the session id) — gets a
    /// friendly message instead of Strava's raw "duplicate of activity N".
    static func processingError(_ message: String) -> StravaError {
        if message.range(of: "duplicate", options: .caseInsensitive) != nil {
            return .uploadFailed("This session is already on Strava.")
        }
        return .uploadFailed(message)
    }

    static func decodeStatus(_ data: Data) throws -> StravaUploadStatus {
        do {
            return try JSONDecoder().decode(StravaUploadStatus.self, from: data)
        } catch {
            throw StravaError.uploadFailed("Unexpected response from Strava.")
        }
    }
}

/// The `/v3/uploads` status payload. `activityID` stays `nil` while Strava is
/// still processing; `error` is set if the file is rejected.
struct StravaUploadStatus: Decodable, Sendable {
    let id: Int
    let activityID: Int?
    let error: String?
    let status: String?

    enum CodingKeys: String, CodingKey {
        case id
        case activityID = "activity_id"
        case error
        case status
    }
}

/// No-op uploader for previews and tests.
public struct StubStravaClient: StravaUploading {
    public init() {}
    public func createActivity(_ activity: StravaActivity, accessToken: String) async throws {}
    public func uploadFile(_ upload: StravaUpload, accessToken: String) async throws -> Int { 0 }
}
