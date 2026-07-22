import Foundation
import ActivityKit
import os
import UIKit
import Domain

/// Push-to-start plumbing for the in-progress-dive Live Activity (#18, stage 2).
///
/// A Live Activity can't be *started* from the background with `Activity.request`
/// (that needs the foreground). iOS 17.2+ lets a backend start one via an APNs
/// push using a per-app "push-to-start" token. We observe that token, stash the
/// latest hex (plus the APNs environment this build targets) in `UserDefaults`,
/// and `LiveSessionMonitor` hands it to the Cloudflare Worker when a watch session
/// arrives while the app is backgrounded — the Worker signs the APNs request and
/// the Live Activity appears with no foreground needed. The local notification
/// (stage 1) stays as the fallback for older OSes / no token / a failed push.

/// Stores the current push-to-start token + its APNs environment. Kept dead
/// simple (UserDefaults, `Sendable`) so both the token observer and
/// `LiveSessionMonitor` can touch it from any actor.
enum PushToStartStore {
    /// Worker endpoint that relays the APNs push-to-start. Same public apex host as
    /// the privacy/support pages (see `Server/src/index.ts`); routed by path there.
    static let triggerURL = URL(string: "https://divefree.software-engineer.ing/live-activity/start")!

    private static let tokenKey = "liveActivityPushToStartTokenHex"
    private static let envKey = "liveActivityPushEnvironment"

    /// APNs environment THIS build's push token belongs to. A push-to-start token
    /// is only valid against the APNs host matching the `aps-environment` the app
    /// was signed with, and we can't reliably read the embedded provisioning
    /// profile at runtime — so we key off the build configuration, which mirrors
    /// how Xcode maps `aps-environment`:
    ///   • DEBUG / development-signed          → APNs **sandbox**
    ///   • Release (TestFlight, App Store)     → APNs **production**
    /// TestFlight is a Release build, so it (correctly) reports production. The
    /// Worker uses this to pick api.sandbox.push.apple.com vs api.push.apple.com.
    static var apnsEnvironment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    static func store(tokenHex: String) {
        let defaults = UserDefaults.standard
        defaults.set(tokenHex, forKey: tokenKey)
        defaults.set(apnsEnvironment, forKey: envKey)
    }

    /// The latest push-to-start token and the APNs env it belongs to, or `nil` when
    /// none has been captured yet (pre-iOS-17.2, or before the first token arrives).
    static func current() -> (token: String, env: String)? {
        let defaults = UserDefaults.standard
        guard let token = defaults.string(forKey: tokenKey), !token.isEmpty else { return nil }
        return (token, defaults.string(forKey: envKey) ?? apnsEnvironment)
    }
}

/// Observes push-to-start token updates for the dive Live Activity and persists
/// each one.
enum PushToStartRegistrar {
    private static let log = Logger(subsystem: "org.yurko.divefree", category: "PushToStart")

    /// Starts the long-lived token observer. Runs for the process lifetime, so it's
    /// launched from app init — a background WatchConnectivity launch captures and
    /// rotates the token too, not just a foreground open. iOS 17.2+ only.
    @available(iOS 17.2, *)
    static func start() {
        Task.detached(priority: .utility) {
            for await tokenData in Activity<DiveActivityAttributes>.pushToStartTokenUpdates {
                let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                PushToStartStore.store(tokenHex: hex)
                log.notice("Captured Live Activity push-to-start token (\(hex.count, privacy: .public) hex chars).")
            }
        }
    }
}

/// Injectable seam so `LiveSessionMonitor` can fire the push-to-start trigger
/// without a live network/APNs round-trip in tests.
protocol LiveSessionPushTrigger: Sendable {
    /// Asks the Worker to APNs-start the Live Activity for `snapshot`. Returns
    /// whether the Worker accepted the relay (HTTP 2xx). `false` — no token, a
    /// transport error, or an APNs rejection — is the caller's cue to fall back to
    /// the local notification. A `true` is best-effort (APNs delivery isn't
    /// guaranteed) but means the request was accepted.
    func trigger(snapshot: LiveSessionSnapshot, token: String, env: String) async -> Bool
}

/// Real trigger: POSTs `{token, env, contentState}` to the Worker.
struct WorkerLiveSessionPushTrigger: LiveSessionPushTrigger {
    private let log = Logger(subsystem: "org.yurko.divefree", category: "PushToStart")

    /// The JSON body the Worker forwards into the APNs payload. `contentState`
    /// mirrors `DiveActivityAttributes.ContentState` exactly (a wrapped
    /// `LiveSessionSnapshot`) so iOS decodes it straight into the Live Activity's
    /// state. Encoded with `JSONEncoder`'s defaults — crucially the default
    /// `.deferredToDate` date strategy — because ActivityKit decodes a remote
    /// `content-state` with the matching default decoder; keeping both on the
    /// defaults round-trips the `Date` fields (startTime/updatedAt) correctly.
    private struct Body: Encodable {
        let token: String
        let env: String
        let contentState: DiveActivityAttributes.ContentState
    }

    func trigger(snapshot: LiveSessionSnapshot, token: String, env: String) async -> Bool {
        // FIX 6: this fires from a WCSession background wake, where iOS can suspend the
        // process the moment the WC callback returns. Guard the network round-trip with a
        // UIKit background task so it isn't killed mid-flight, and cap the request at 10 s
        // (vs URLSession's 60 s default) so the push-vs-notification decision resolves
        // inside the background window.
        //
        // The background task carries an `expirationHandler`: if iOS runs out the wall
        // clock before the request finishes it cancels the in-flight URLSession task (so
        // we don't linger) and ends the background task. The round-trip runs in its own
        // child task so that (main-actor) handler can cancel it. Ending is funnelled
        // through a main-actor guard that flips the identifier to `.invalid` on the first
        // end, so the normal-completion `defer` and the expiration handler can never
        // double-end the same identifier (a hard crash if attempted twice).
        let guardBox = BackgroundTaskGuard()
        let request = makeRequest(snapshot: snapshot, token: token, env: env)
        let requestTask: Task<(Data, URLResponse), Error>? = request.map { req in
            Task { try await URLSession.shared.data(for: req) }
        }
        // Begin the background task and register its identifier with the guard in the SAME
        // main-actor turn, so the expiration handler (also main-actor) can't fire against
        // an un-adopted identifier and leak it. UIKit invokes the handler on the main
        // thread, so assume the main actor to reach the guard.
        let identifier = await MainActor.run { () -> UIBackgroundTaskIdentifier in
            let id = UIApplication.shared.beginBackgroundTask(withName: "live-activity-push") {
                MainActor.assumeIsolated { guardBox.expire() }
            }
            guardBox.adopt(id, requestTask: requestTask)
            return id
        }
        defer { Task { @MainActor in guardBox.endIfNeeded() } }

        // Bail if the request body failed to encode, or the system refused the
        // background task (`.invalid`) — no window to run in.
        guard let requestTask, identifier != .invalid else {
            if identifier == .invalid {
                log.error("Push-to-start trigger skipped: no background time available.")
            }
            return false
        }

        do {
            let (_, response) = try await requestTask.value
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let ok = (200..<300).contains(code)
            if !ok { log.error("Push-to-start trigger rejected (HTTP \(code, privacy: .public)).") }
            return ok
        } catch {
            log.error("Push-to-start trigger failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Builds the POST request, or `nil` if the body fails to encode.
    private func makeRequest(snapshot: LiveSessionSnapshot, token: String, env: String) -> URLRequest? {
        var request = URLRequest(url: PushToStartStore.triggerURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let body = Body(token: token, env: env, contentState: .init(snapshot: snapshot))
            request.httpBody = try JSONEncoder().encode(body)
            return request
        } catch {
            log.error("Push-to-start body encode failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

/// Main-actor guard that owns the UIKit background-task identifier so it is ended
/// exactly once — from whichever of normal completion or the `expirationHandler`
/// fires first. `endBackgroundTask` traps if called twice on the same identifier, so
/// we flip the stored identifier to `.invalid` on the first end and guard every
/// subsequent call. Main-actor confined because every `UIApplication` background-task
/// call must be, which also removes any data race on the stored identifier.
@MainActor
private final class BackgroundTaskGuard {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var requestTask: Task<(Data, URLResponse), Error>?

    /// Records the identifier and its request task after the task begins. If the
    /// expiration handler already fired (rare, before we get here) the identifier is
    /// still `.invalid`, and we end the just-issued one to avoid leaking it.
    func adopt(_ identifier: UIBackgroundTaskIdentifier, requestTask: Task<(Data, URLResponse), Error>?) {
        self.identifier = identifier
        self.requestTask = requestTask
    }

    /// Expiration path: cancel the in-flight round-trip, then end the task.
    func expire() {
        requestTask?.cancel()
        endIfNeeded()
    }

    func endIfNeeded() {
        let id = identifier
        guard id != .invalid else { return }
        identifier = .invalid
        requestTask = nil
        UIApplication.shared.endBackgroundTask(id)
    }
}
