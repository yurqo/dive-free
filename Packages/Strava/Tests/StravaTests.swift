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

    @Test("session maps to a Swim activity")
    func mapsToSwim() {
        let activity = StravaActivity(session: DiveSession(startTime: Date()))
        #expect(activity.type == "Swim")
    }

    @Test("activity form fields carry sport type, elapsed time, and start date")
    func activityFormFields() {
        let activity = StravaActivity(
            name: "Freedive Session",
            type: "Swim",
            startDate: Date(timeIntervalSince1970: 0),
            elapsedSeconds: 1800,
            description: "2 dives"
        )
        let fields = activity.formFields
        #expect(fields["sport_type"] == "Swim")
        #expect(fields["elapsed_time"] == "1800")
        #expect(fields["name"] == "Freedive Session")
        #expect(fields["description"] == "2 dives")
        #expect(fields["start_date_local"] != nil)
    }

    @Test("raw coordinates are not folded into the description")
    func coordinatesNotInDescription() {
        let session = DiveSession(
            startTime: Date(timeIntervalSince1970: 0),
            endTime: Date(timeIntervalSince1970: 60),
            location: GeoPoint(latitude: 20.5, longitude: -87.0)
        )
        let description = StravaActivity(session: session).description
        // The GPS position rides in the uploaded track now, not the text.
        #expect(description?.contains("📍") == false)
        #expect(description?.contains("20.5") == false)
        #expect(description?.contains("max depth") == true)
    }
}

@Suite("StravaClient upload")
struct StravaClientUploadTests {
    private func client(
        status: Int,
        capture: (@Sendable (URLRequest) -> Void)? = nil
    ) -> StravaClient {
        StravaClient(perform: { request in
            capture?(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(), response)
        })
    }

    private let activity = StravaActivity(name: "x", startDate: Date(timeIntervalSince1970: 0), elapsedSeconds: 10)

    @Test("a 2xx response posts to /activities with a bearer token")
    func uploadsSuccessfully() async throws {
        let captured = CapturedRequest()
        let client = client(status: 201, capture: { captured.set($0) })
        try await client.createActivity(activity, accessToken: "TOKEN")

        let request = captured.value
        #expect(request?.httpMethod == "POST")
        #expect(request?.url?.absoluteString.hasSuffix("/activities") == true)
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer TOKEN")
        let body = request?.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(body.contains("sport_type=Swim"))
    }

    @Test("401 surfaces as unauthorized")
    func unauthorized() async {
        await #expect(throws: StravaError.unauthorized) {
            try await client(status: 401).createActivity(activity, accessToken: "T")
        }
    }

    @Test("429 surfaces as rateLimited")
    func rateLimited() async {
        await #expect(throws: StravaError.rateLimited) {
            try await client(status: 429).createActivity(activity, accessToken: "T")
        }
    }

    @Test("other non-2xx surfaces as server error")
    func serverError() async {
        await #expect(throws: StravaError.server(status: 500)) {
            try await client(status: 500).createActivity(activity, accessToken: "T")
        }
    }
}

private final class CapturedRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var request: URLRequest?
    func set(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; self.request = request }
    var value: URLRequest? { lock.lock(); defer { lock.unlock() }; return request }
}

/// Builds an HTTP response for a request, for the perform stubs below.
private func httpResponse(_ status: Int, for request: URLRequest) -> HTTPURLResponse {
    HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
}

/// Thread-safe call counter for the poll stubs.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    @discardableResult func increment() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@Suite("StravaClient file upload")
struct StravaClientFileUploadTests {
    private let upload = StravaUpload(data: Data([0x0E, 0x10, 0x00, 0x00]), dataType: "fit", name: "Freedive Session", externalID: "EID")

    @Test("uploads the file as multipart and returns the activity id once ready")
    func uploadsAndReturnsActivityID() async throws {
        let captured = CapturedRequest()
        let client = StravaClient(perform: { request in
            if request.url!.absoluteString.hasSuffix("/uploads") {
                captured.set(request)
                return (Data("{\"id\":123,\"activity_id\":999}".utf8), httpResponse(201, for: request))
            }
            return (Data(), httpResponse(200, for: request)) // PUT sport_type
        }, sleep: { _ in })

        let id = try await client.uploadFile(upload, accessToken: "TOKEN")
        #expect(id == 999)

        let request = captured.value
        #expect(request?.httpMethod == "POST")
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer TOKEN")
        #expect(request?.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        let body = request?.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(body.contains("name=\"data_type\""))
        #expect(body.contains("filename=\"dive.fit\""))
    }

    @Test("polls the upload until Strava attaches an activity id")
    func pollsUntilReady() async throws {
        let polls = Counter()
        let client = StravaClient(perform: { request in
            let url = request.url!.absoluteString
            if request.httpMethod == "POST", url.hasSuffix("/uploads") {
                return (Data("{\"id\":123,\"activity_id\":null}".utf8), httpResponse(201, for: request))
            }
            if request.httpMethod == "GET", url.contains("/uploads/123") {
                let ready = polls.increment() >= 2
                let body = ready ? "{\"id\":123,\"activity_id\":999}" : "{\"id\":123,\"activity_id\":null}"
                return (Data(body.utf8), httpResponse(200, for: request))
            }
            return (Data(), httpResponse(200, for: request)) // PUT sport_type
        }, pollInterval: .milliseconds(1), maxPollAttempts: 5, sleep: { _ in })

        #expect(try await client.uploadFile(upload, accessToken: "T") == 999)
        #expect(polls.value == 2)
    }

    @Test("a processing error from Strava surfaces as uploadFailed")
    func processingErrorFails() async {
        let client = StravaClient(perform: { request in
            (Data("{\"id\":1,\"activity_id\":null,\"error\":\"your file could not be parsed\"}".utf8), httpResponse(201, for: request))
        }, sleep: { _ in })
        await #expect(throws: StravaError.uploadFailed("your file could not be parsed")) {
            try await client.uploadFile(upload, accessToken: "T")
        }
    }

    @Test("a duplicate is mapped to a friendly already-on-Strava message")
    func duplicateBecomesFriendly() async {
        let client = StravaClient(perform: { request in
            (Data("{\"id\":1,\"activity_id\":null,\"error\":\"duplicate of activity 7\"}".utf8), httpResponse(201, for: request))
        }, sleep: { _ in })
        await #expect(throws: StravaError.uploadFailed("This session is already on Strava.")) {
            try await client.uploadFile(upload, accessToken: "T")
        }
    }

    @Test("a transient poll failure is tolerated; polling continues until ready")
    func toleratesTransientPollFailure() async throws {
        let polls = Counter()
        let client = StravaClient(perform: { request in
            let url = request.url!.absoluteString
            if request.httpMethod == "POST", url.hasSuffix("/uploads") {
                return (Data("{\"id\":123,\"activity_id\":null}".utf8), httpResponse(201, for: request))
            }
            if request.httpMethod == "GET", url.contains("/uploads/123") {
                let n = polls.increment()
                if n == 1 { return (Data("upstream hiccup".utf8), httpResponse(500, for: request)) }
                return (Data("{\"id\":123,\"activity_id\":999}".utf8), httpResponse(200, for: request))
            }
            return (Data(), httpResponse(200, for: request)) // PUT sport_type
        }, pollInterval: .milliseconds(1), maxPollAttempts: 5, sleep: { _ in })

        #expect(try await client.uploadFile(upload, accessToken: "T") == 999)
    }

    @Test("never finishing processing surfaces as uploadTimedOut")
    func timesOut() async {
        let client = StravaClient(perform: { request in
            (Data("{\"id\":1,\"activity_id\":null}".utf8), httpResponse(request.httpMethod == "POST" ? 201 : 200, for: request))
        }, pollInterval: .milliseconds(1), maxPollAttempts: 2, sleep: { _ in })
        await #expect(throws: StravaError.uploadTimedOut) {
            try await client.uploadFile(upload, accessToken: "T")
        }
    }

    @Test("a 401 on the initial upload surfaces as unauthorized")
    func unauthorizedOnUpload() async {
        let client = StravaClient(perform: { request in
            (Data(), httpResponse(401, for: request))
        }, sleep: { _ in })
        await #expect(throws: StravaError.unauthorized) {
            try await client.uploadFile(upload, accessToken: "T")
        }
    }
}

@Suite("StravaFIT")
struct StravaFITTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func diveWithProfile() -> Dive {
        Dive(
            startTime: t0.addingTimeInterval(10), endTime: t0.addingTimeInterval(40), maxDepthMeters: 12,
            samples: [
                DepthSample(timestamp: t0.addingTimeInterval(10), depthMeters: 0),
                DepthSample(timestamp: t0.addingTimeInterval(25), depthMeters: 12),
                DepthSample(timestamp: t0.addingTimeInterval(40), depthMeters: 0),
            ]
        )
    }

    @Test("returns nil with no position source")
    func nilWithoutPosition() {
        let session = DiveSession(startTime: t0, dives: [diveWithProfile()])
        #expect(StravaFIT.build(session) == nil)
    }

    @Test("returns nil with a position but no time-series data")
    func nilWithoutSeries() {
        let session = DiveSession(startTime: t0, location: GeoPoint(latitude: 1, longitude: 2))
        #expect(StravaFIT.build(session) == nil)
    }

    @Test("builds a FIT with track, depth, heart-rate, temperature, and calories")
    func buildsFullFIT() throws {
        let session = DiveSession(
            startTime: t0,
            endTime: t0.addingTimeInterval(100),
            dives: [diveWithProfile()],
            location: GeoPoint(latitude: 20.5, longitude: -87.0),
            track: [
                TrackPoint(timestamp: t0, location: GeoPoint(latitude: 20.5, longitude: -87.0)),
                TrackPoint(timestamp: t0.addingTimeInterval(100), location: GeoPoint(latitude: 20.6, longitude: -87.1)),
            ],
            heartRateSamples: [
                HeartRateSample(timestamp: t0, bpm: 70),
                HeartRateSample(timestamp: t0.addingTimeInterval(100), bpm: 90),
            ],
            temperatureSamples: [
                TemperatureSample(timestamp: t0.addingTimeInterval(10), celsius: 21),
            ],
            activeEnergyKilocalories: 123.4
        )
        let data = try #require(StravaFIT.build(session))
        let fit = try #require(FITDecoder.decode(data), "structurally valid FIT")
        #expect(fit.headerCRCOK)
        #expect(fit.fileCRCOK)

        // file_id (msg 0) declares an activity (type = 4).
        let fileID = try #require(fit.messages.first { $0.globalNum == 0 })
        #expect(fileID.u8(0) == 4)

        // session (msg 18) carries the rounded calories + swimming sport (5).
        let sessionMsg = try #require(fit.messages.first { $0.globalNum == 18 })
        #expect(sessionMsg.u16(11) == 123)
        #expect(sessionMsg.u8(5) == 5)

        // lap (19) and activity (34) messages are present.
        #expect(fit.messages.contains { $0.globalNum == 19 })
        #expect(fit.messages.contains { $0.globalNum == 34 })

        // One record (msg 20) per distinct instant (t0, +10, +25, +40, +100),
        // each positioned; the deepest carries altitude, plus the HR + temp streams.
        let records = fit.messages.filter { $0.globalNum == 20 }
        #expect(records.count == 5)
        #expect(records.allSatisfy { $0.i32(0) != nil && $0.i32(1) != nil })
        #expect(records.contains { $0.u16(2) == 2440 }) // depth 12 m → (−12+500)·5
        #expect(records.contains { $0.u8(3) == 70 })     // heart rate
        #expect(records.contains { $0.i8(13) == 21 })    // water temperature
    }

    @Test("builds from a fixed location with zero calories when energy is unknown")
    func buildsFromFixedLocation() throws {
        let session = DiveSession(
            startTime: t0,
            endTime: t0.addingTimeInterval(60),
            location: GeoPoint(latitude: 1, longitude: 2),
            heartRateSamples: [
                HeartRateSample(timestamp: t0, bpm: 70),
                HeartRateSample(timestamp: t0.addingTimeInterval(60), bpm: 80),
            ]
        )
        let data = try #require(StravaFIT.build(session))
        let fit = try #require(FITDecoder.decode(data))
        let sessionMsg = try #require(fit.messages.first { $0.globalNum == 18 })
        #expect(sessionMsg.u16(11) == 0) // no active energy → 0 kcal
        let records = fit.messages.filter { $0.globalNum == 20 }
        #expect(!records.isEmpty)
        // No temperature samples → every record uses the FIT sint8 "invalid" sentinel.
        #expect(records.allSatisfy { $0.fields[13] == [0x7F] })
    }

    @Test("depthMeters is zero at the surface and the sampled depth underwater")
    func depthAtInstant() {
        let session = DiveSession(startTime: t0, dives: [diveWithProfile()])
        #expect(StravaFIT.depthMeters(in: session, at: t0) == 0)
        #expect(StravaFIT.depthMeters(in: session, at: t0.addingTimeInterval(25)) == 12)
    }

    @Test("interpolate clamps to endpoints and lerps between samples")
    func interpolates() {
        #expect(StravaFIT.interpolate([], at: t0) == nil)
        let samples = [(t0, 10.0), (t0.addingTimeInterval(10), 20.0)]
        #expect(StravaFIT.interpolate(samples, at: t0.addingTimeInterval(-5)) == 10)
        #expect(StravaFIT.interpolate(samples, at: t0.addingTimeInterval(5)) == 15)
        #expect(StravaFIT.interpolate(samples, at: t0.addingTimeInterval(50)) == 20)
    }
}

// MARK: - Minimal FIT decoder (test-only) to validate the encoder's bytes

/// A decoded FIT data message: its global message number and raw field bytes.
private struct FITMessage {
    let globalNum: UInt16
    let fields: [UInt8: [UInt8]]

    func u8(_ field: UInt8) -> UInt8? { fields[field]?.first }
    func i8(_ field: UInt8) -> Int8? { fields[field]?.first.map { Int8(bitPattern: $0) } }
    func u16(_ field: UInt8) -> UInt16? {
        guard let b = fields[field], b.count >= 2 else { return nil }
        return UInt16(b[0]) | (UInt16(b[1]) << 8)
    }
    func i32(_ field: UInt8) -> Int32? {
        guard let b = fields[field], b.count >= 4 else { return nil }
        return Int32(bitPattern: UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24))
    }
}

/// Walks a FIT file: validates the header + both CRCs and decodes every data
/// message using the definition messages it carries. Returns nil on any
/// structural fault (so a malformed encoder output fails the test).
private enum FITDecoder {
    static func decode(_ data: Data) -> (messages: [FITMessage], headerCRCOK: Bool, fileCRCOK: Bool)? {
        let bytes = [UInt8](data)
        guard bytes.count >= 16, bytes[0] == 14,
              Array(bytes[8..<12]) == Array(".FIT".utf8) else { return nil }
        let dataSize = Int(UInt32(bytes[4]) | (UInt32(bytes[5]) << 8) | (UInt32(bytes[6]) << 16) | (UInt32(bytes[7]) << 24))
        guard 14 + dataSize + 2 == bytes.count else { return nil }

        let headerCRC = UInt16(bytes[12]) | (UInt16(bytes[13]) << 8)
        let headerCRCOK = headerCRC == StravaFIT.crc16(Array(bytes[0..<12]))
        let fileCRC = UInt16(bytes[bytes.count - 2]) | (UInt16(bytes[bytes.count - 1]) << 8)
        let fileCRCOK = fileCRC == StravaFIT.crc16(Array(bytes[0..<(bytes.count - 2)]))

        var definitions: [UInt8: (global: UInt16, fields: [(num: UInt8, size: Int)])] = [:]
        var messages: [FITMessage] = []
        var i = 14
        let end = 14 + dataSize
        while i < end {
            let header = bytes[i]; i += 1
            let local = header & 0x0F
            if header & 0x40 != 0 { // definition message
                guard i + 5 <= end else { return nil }
                let global = UInt16(bytes[i + 2]) | (UInt16(bytes[i + 3]) << 8)
                let count = Int(bytes[i + 4]); i += 5
                var fields: [(UInt8, Int)] = []
                for _ in 0..<count {
                    guard i + 3 <= end else { return nil }
                    fields.append((bytes[i], Int(bytes[i + 1]))); i += 3
                }
                definitions[local] = (global, fields)
            } else { // data message
                guard let def = definitions[local] else { return nil }
                var map: [UInt8: [UInt8]] = [:]
                for (num, size) in def.fields {
                    guard i + size <= end else { return nil }
                    map[num] = Array(bytes[i..<(i + size)]); i += size
                }
                messages.append(FITMessage(globalNum: def.global, fields: map))
            }
        }
        guard i == end else { return nil }
        return (messages, headerCRCOK, fileCRCOK)
    }
}

@Suite("Multipart encoding")
struct MultipartEncodingTests {
    @Test("includes text fields and a file part bounded by the boundary")
    func encodesParts() {
        let body = MultipartEncoding.body(
            fields: ["data_type": "gpx", "name": "Freedive"],
            file: .init(name: "file", filename: "dive.gpx", contentType: "application/gpx+xml", data: Data("XML".utf8)),
            boundary: "BDRY"
        )
        let string = String(decoding: body, as: UTF8.self)
        #expect(string.contains("--BDRY\r\n"))
        #expect(string.contains("name=\"data_type\""))
        #expect(string.contains("filename=\"dive.gpx\""))
        #expect(string.contains("Content-Type: application/gpx+xml"))
        #expect(string.contains("XML"))
        #expect(string.hasSuffix("--BDRY--\r\n"))
    }
}

@Suite("StravaExport")
@MainActor
struct StravaExportTests {
    /// Uploader that fails the first N attempts with `unauthorized`, then succeeds,
    /// recording the tokens each path was given.
    private final class RetryUploader: StravaUploading, @unchecked Sendable {
        var failFirst: Int
        private(set) var tokens: [String] = []
        private(set) var fileTokens: [String] = []
        init(failFirst: Int) { self.failFirst = failFirst }
        func createActivity(_ activity: StravaActivity, accessToken: String) async throws {
            tokens.append(accessToken)
            if failFirst > 0 { failFirst -= 1; throw StravaError.unauthorized }
        }
        func uploadFile(_ upload: StravaUpload, accessToken: String) async throws -> Int {
            fileTokens.append(accessToken)
            if failFirst > 0 { failFirst -= 1; throw StravaError.unauthorized }
            return 1
        }
    }

    /// A session with a track + heart-rate series, so export takes the file path.
    private func sessionWithStreams() -> DiveSession {
        let t0 = Date()
        return DiveSession(
            startTime: t0,
            endTime: t0.addingTimeInterval(60),
            location: GeoPoint(latitude: 1, longitude: 2),
            track: [TrackPoint(timestamp: t0, location: GeoPoint(latitude: 1, longitude: 2))],
            heartRateSamples: [HeartRateSample(timestamp: t0, bpm: 70)]
        )
    }

    private func manager(accessToken: String, expired: Bool) -> StravaAuthManager {
        let tokens = StravaTokens(
            accessToken: accessToken,
            refreshToken: "RT",
            expiresAt: Date().addingTimeInterval(expired ? -10 : 3600)
        )
        return StravaAuthManager(
            store: InMemoryTokenStore(tokens: tokens),
            webAuth: StubWebAuth(callback: URL(string: "x://y")!),
            perform: tokenResponse(accessToken: "REFRESHED", expiresAt: Date().addingTimeInterval(3600).timeIntervalSince1970)
        )
    }

    @Test("export uploads with the current token when authorized")
    func exportsDirectly() async throws {
        let uploader = RetryUploader(failFirst: 0)
        try await StravaExport.export(DiveSession(startTime: Date()), auth: manager(accessToken: "AT", expired: false), uploader: uploader)
        #expect(uploader.tokens == ["AT"])
    }

    @Test("a 401 triggers a refresh and one retry")
    func refreshesAndRetriesOn401() async throws {
        let uploader = RetryUploader(failFirst: 1)
        try await StravaExport.export(DiveSession(startTime: Date()), auth: manager(accessToken: "AT", expired: false), uploader: uploader)
        // First attempt with the stored token, retry with the refreshed one.
        #expect(uploader.tokens == ["AT", "REFRESHED"])
    }

    @Test("a session with streams takes the file-upload path")
    func exportsFileWhenStreamsPresent() async throws {
        let uploader = RetryUploader(failFirst: 0)
        try await StravaExport.export(sessionWithStreams(), auth: manager(accessToken: "AT", expired: false), uploader: uploader)
        #expect(uploader.fileTokens == ["AT"])
        #expect(uploader.tokens.isEmpty)
    }

    @Test("a 401 during file upload refreshes and retries")
    func refreshesFileUploadOn401() async throws {
        let uploader = RetryUploader(failFirst: 1)
        try await StravaExport.export(sessionWithStreams(), auth: manager(accessToken: "AT", expired: false), uploader: uploader)
        #expect(uploader.fileTokens == ["AT", "REFRESHED"])
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

    @Test("token exchange posts the code as JSON to the proxy /token endpoint")
    func tokenExchangeBody() throws {
        let proxy = URL(string: "https://proxy.example.com")!
        let request = StravaOAuth.tokenExchangeRequest(code: "C", proxyBaseURL: proxy)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/token")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let json = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String]
        #expect(json == ["code": "C"])
        // The client secret never leaves the proxy.
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(!body.contains("client_secret"))
    }

    @Test("refresh posts the refresh token as JSON to the proxy /refresh endpoint")
    func refreshBody() throws {
        let proxy = URL(string: "https://proxy.example.com")!
        let request = StravaOAuth.refreshRequest(refreshToken: "RT", proxyBaseURL: proxy)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/refresh")
        let json = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String]
        #expect(json == ["refresh_token": "RT"])
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(!body.contains("client_secret"))
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
