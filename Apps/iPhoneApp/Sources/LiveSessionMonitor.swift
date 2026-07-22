import Foundation
import os
import Observation
import ActivityKit
import UserNotifications
import UIKit
import Domain

/// Reflects an in-progress Watch session on the iPhone (#118): publishes the
/// latest `LiveSessionSnapshot` for the in-app banner and mirrors it into a
/// Live Activity (Lock Screen / Dynamic Island). Fed by
/// `SyncManager.onReceiveLiveSession`.
///
/// Robustness for the diving case (phone on the boat, Watch in the water):
/// snapshots are latest-wins, so a missed update just leaves the last one showing
/// (the UI grays it as an estimate past `staleThreshold`); if nothing arrives for
/// `maxAge` and no "ended" came through, it dismisses itself; and `dismiss()` is
/// the manual escape hatch for a dead Watch battery, guarding against a late
/// snapshot for the same session resurrecting the display.
///
/// Closed/background phone (#18): a Live Activity can't be *started* from the
/// background (`Activity.request` needs the foreground without a push backend), so
/// when the first snapshot of a session arrives and no activity starts, we try two
/// things (once per session each): on iOS 17.2+ with a stored push-to-start token
/// we ask the Worker to APNs-start the Live Activity (`LiveSessionPushTrigger`);
/// and — as the fallback when that isn't possible or the push fails — we post a
/// single local notification ("session running on your watch"). Tapping the
/// notification opens the app; the next per-snapshot retry then starts the real
/// Live Activity and the notification is removed. The notification is likewise
/// removed when the session ends, is dismissed, or the activity otherwise takes over.
@MainActor
@Observable
final class LiveSessionMonitor {
    /// The live session to display, or nil when none is active/shown.
    private(set) var snapshot: LiveSessionSnapshot?

    /// Start time of a session the user manually dismissed — ignore further
    /// snapshots for it so a queued/stale update can't bring it back. FIX 3(b):
    /// persisted in `UserDefaults` (`dismissedStartKey`) so a manual dismiss
    /// survives a background relaunch. WCSession redelivers `receivedApplication
    /// Context` on every activation, so without this a dismissed (or dead) session
    /// would resurrect its banner on the next phone launch.
    @ObservationIgnored private var dismissedStart: Date? {
        didSet { Self.persistDismissedStart(dismissedStart) }
    }
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    /// FIX 2: bounds an init-time adoption made with no snapshot yet. At launch we
    /// keep an activity left over from a previous process alive (a genuine
    /// mid-session relaunch must not drop it before the first redelivered snapshot),
    /// but if no snapshot arrives within `initAdoptionGracePeriod` the activity is
    /// phantom (session already over, or a stale pushed copy) and gets ended.
    /// Cancelled on the first successful `ingest`.
    @ObservationIgnored private var initAdoptionGrace: Task<Void, Never>?
    @ObservationIgnored private var activity: Activity<DiveActivityAttributes>?
    /// Long-lived observer of `activityUpdates` that adopts push-to-start activities
    /// (created outside our `Activity.request` path) as they appear (see FIX 1b).
    @ObservationIgnored private var activityObserver: Task<Void, Never>?
    /// Once-per-session latch for the background fallback notification.
    @ObservationIgnored private var notificationLatch = LiveSessionNotificationLatch()
    /// Separate once-per-session latch for the push-to-start trigger — an attempt
    /// per session, independent of the notification latch, so a session fires the
    /// APNs trigger at most once regardless of the ~2 s snapshot cadence.
    @ObservationIgnored private var pushLatch = LiveSessionNotificationLatch()
    /// Session start + wall-clock time of a push-to-start trigger that is either in
    /// flight or was accepted (2xx) by the Worker. FIX 4: recorded BEFORE launching
    /// the trigger task (not only after the 2xx response), so a snapshot arriving
    /// while the request is still on the wire doesn't post the fallback notification
    /// on top of the pushed Live Activity that's about to appear. `accepted` flips
    /// true on 2xx; the whole record is cleared on trigger failure so the next
    /// snapshot can post the fallback.
    @ObservationIgnored private var pushAttempt: (start: Date, at: Date, accepted: Bool)?
    /// How long after a push trigger we withhold the fallback notification: the
    /// pushed activity typically arrives (and is adopted) within a second or two;
    /// after the window, no activity means the notification is the right fallback.
    private static let pushGrace: TimeInterval = 10
    /// FIX 2: grace period for an init-time adoption made without a snapshot — long
    /// enough for WCSession to redeliver the in-progress session's context after a
    /// relaunch, short enough that a phantom activity doesn't linger.
    private static let initAdoptionGracePeriod: TimeInterval = 90
    @ObservationIgnored private let notifier: LiveSessionNotifier
    @ObservationIgnored private let pushTrigger: LiveSessionPushTrigger
    @ObservationIgnored private let log = Logger(subsystem: "org.yurko.divefree", category: "LiveSession")

    init(
        notifier: LiveSessionNotifier = SystemLiveSessionNotifier(),
        pushTrigger: LiveSessionPushTrigger = WorkerLiveSessionPushTrigger()
    ) {
        self.notifier = notifier
        self.pushTrigger = pushTrigger
        // FIX 3(b): restore a manual dismiss made in a previous process so a
        // redelivered application context can't resurrect the dismissed session. An
        // initial assignment inside `init` does NOT fire the property's `didSet`, so
        // this loads the persisted value without a redundant write-back.
        dismissedStart = Self.loadDismissedStart()
        // Adopt an activity that outlived a previous launch so we can update/end it.
        // FIX 2: a fresh launch mid-session must keep this activity alive until the
        // first redelivered snapshot lands, so we DON'T end it here even though we
        // have no snapshot yet — instead we start a bounded grace timer; if no
        // snapshot arrives it's a phantom (session already ended, or a stale pushed
        // copy) and the timer ends it.
        if let adopted = Activity<DiveActivityAttributes>.activities.first {
            activity = adopted
            startInitAdoptionGrace()
        }
        observeActivityUpdates()
    }

    /// FIX 2: ends an init-adopted activity if no snapshot arrives within
    /// `initAdoptionGracePeriod`. Cancelled by the first `ingest` (real session).
    private func startInitAdoptionGrace() {
        initAdoptionGrace = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.initAdoptionGracePeriod))
            guard let self, !Task.isCancelled, self.snapshot == nil else { return }
            // No snapshot ever arrived for the adopted activity — it's phantom.
            self.endActivity()
        }
    }

    /// Observes Live Activities that start OUTSIDE our `Activity.request` path —
    /// namely push-to-start (FIX 1b): APNs creates the activity directly in this
    /// (usually backgrounded) process, so `updateActivity` never sees it and would
    /// otherwise re-`request` a duplicate the next time the app foregrounds. Apple
    /// recommends watching `activityUpdates` for exactly this. Runs for the process
    /// lifetime on a background task, hopping to the main actor to adopt each one.
    private func observeActivityUpdates() {
        activityObserver = Task.detached { [weak self] in
            for await activity in Activity<DiveActivityAttributes>.activityUpdates {
                // `Activity` isn't Sendable; box it for the main-actor hop (same
                // pattern as `SendableActivity` elsewhere).
                let box = SendableActivity(activity)
                await MainActor.run { self?.adopt(box.value) }
            }
        }
    }

    /// Applies an incoming snapshot: end on the terminal one, otherwise show and
    /// update (unless the user dismissed this exact session).
    func ingest(_ snapshot: LiveSessionSnapshot) {
        // FIX 2: a real snapshot arrived, so the init-adoption grace timer's job is
        // done — cancel it (any adopted activity is now backed by live data, and
        // `updateActivity`/`clear` below own its lifecycle from here).
        initAdoptionGrace?.cancel()
        initAdoptionGrace = nil
        // FIX 3(a): WCSession redelivers `receivedApplicationContext` on EVERY
        // activation, so a background relaunch can re-ingest the LAST context of a
        // session whose Watch died mid-dive (no terminal snapshot was ever sent).
        // An ACTIVE snapshot older than `maxAge` is that dead session — treat it
        // like a terminal one: clear any lingering notification for its start time,
        // but do NOT display it and do NOT fire a push (which, from a background
        // wake, could pop a stale Live Activity hours later).
        if snapshot.isActive, snapshot.isExpired(asOf: Date()) {
            // FIX 3: this is a terminal-WITHOUT-resurrection teardown for a dead-watch
            // session (never sent an "ended" snapshot). If the user MANUALLY dismissed it,
            // that dismissal must persist across relaunches — so preserve `dismissedStart`
            // here (unlike the genuine terminal snapshot below, where a cleanly-ended
            // session isn't "dismissed" and clearing is correct). A real NEW active start
            // is the only thing that clears the dismissal (see `dismissedStart = nil` below).
            clear(notificationStart: snapshot.startTime, preserveDismissal: true)
            return
        }
        // Terminal snapshot: tear down and remove this session's fallback
        // notification by its own start time (the latch may be empty after a
        // background relaunch — see `clearNotification(for:)`).
        guard snapshot.isActive else { clear(notificationStart: snapshot.startTime); return }
        if let dismissedStart, snapshot.startTime == dismissedStart { return }
        // FIX 5: a NEW session started while the notification latch still holds a
        // DIFFERENT (older) session's start — the previous session never delivered
        // its terminal snapshot (Watch out of range at stop). Remove the stranded
        // notification for that old start before we proceed, so it doesn't linger in
        // Notification Center once the new session takes over.
        if let stale = notificationLatch.postedStart, stale != snapshot.startTime {
            clearNotification(for: stale)
        }
        dismissedStart = nil
        self.snapshot = snapshot
        // If a Live Activity is (or just became) live, it covers the session and
        // any earlier fallback notification is removed; otherwise — background or
        // activities disabled — run the background-start fallbacks (push-to-start,
        // then local notification).
        if updateActivity(with: snapshot) {
            clearNotification(for: snapshot.startTime)
        } else {
            startInBackground(for: snapshot)
        }
        startWatchdog()
    }

    /// Disconnect state for the UI: the Watch has stopped sending fresh snapshots.
    /// Purely staleness-based — NOT WCSession reachability, which flips false when
    /// the Watch merely dims to Always-On/reduced-motion during a workout (the app
    /// keeps sending, so the session is fine); relying on reachability there caused
    /// a false "Reconnecting" the instant the screen dimmed.
    func isDisconnected(asOf now: Date = Date()) -> Bool {
        snapshot?.isStale(asOf: now) ?? false
    }

    /// Manual phone-side stop for when no "ended" will arrive (Watch battery died
    /// / permanently out of range). Clears the display and blocks resurrection of
    /// the same session; a genuinely new session (different start) still shows.
    func dismiss() {
        let start = snapshot?.startTime
        dismissedStart = start
        snapshot = nil
        endActivity()
        clearNotification(for: start)
        endPushSession()
        watchdog?.cancel()
        watchdog = nil
        initAdoptionGrace?.cancel()
        initAdoptionGrace = nil
    }

    /// Session ended cleanly, expired, or nothing to show — tear everything down,
    /// removing the fallback notification for `notificationStart` (the terminal
    /// snapshot's start time, or the current snapshot's on the watchdog path).
    ///
    /// FIX 3: `preserveDismissal` keeps a persisted MANUAL dismissal intact. Default
    /// `false` for the genuine terminal-snapshot path — a cleanly-ended session isn't
    /// "dismissed", so clearing `dismissedStart` there is correct. The expired-ACTIVE
    /// (dead-watch) branch passes `true`: that session was never cleanly ended, so a
    /// user's manual dismiss of it must survive relaunch and not be wiped by teardown.
    private func clear(notificationStart: Date?, preserveDismissal: Bool = false) {
        if !preserveDismissal { dismissedStart = nil }
        snapshot = nil
        endActivity()
        clearNotification(for: notificationStart)
        endPushSession()
        watchdog?.cancel()
        watchdog = nil
        initAdoptionGrace?.cancel()
        initAdoptionGrace = nil
    }

    /// Terminal-only reset of the push-to-start state (latch + grace record). Kept
    /// out of the per-snapshot `clearNotification` path so a Live Activity the user
    /// swiped away mid-session isn't re-pushed ~2 s later (FIX 3): the push fires
    /// at most once per session, released only when the session genuinely ends
    /// (terminal snapshot / `dismiss()` / watchdog).
    private func endPushSession() {
        pushLatch.clear()
        pushAttempt = nil
    }

    /// Dismisses the display on its own if a session goes silent past `maxAge`
    /// with no terminal snapshot (e.g. the Watch died out of range).
    private func startWatchdog() {
        guard watchdog == nil else { return }
        watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, !Task.isCancelled else { return }
                if let snapshot = self.snapshot, snapshot.isExpired() {
                    self.clear(notificationStart: snapshot.startTime); return
                }
            }
        }
    }

    // MARK: - Live Activity

    private func content(for snapshot: LiveSessionSnapshot) -> ActivityContent<DiveActivityAttributes.ContentState> {
        // The Live Activity grays ("reconnecting") once the snapshot ages past the
        // stale threshold — same staleness signal as the in-app row.
        ActivityContent(
            state: .init(snapshot: snapshot),
            staleDate: snapshot.updatedAt.addingTimeInterval(LiveSessionSnapshot.staleThreshold)
        )
    }

    /// Updates the running Live Activity or tries to start one. Returns whether an
    /// activity is live afterwards — `false` when activities are disabled or a
    /// background start failed, which is the caller's cue to post the fallback
    /// notification (and the true → foreground transition is what removes it).
    @discardableResult
    private func updateActivity(with snapshot: LiveSessionSnapshot) -> Bool {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return false }
        let content = content(for: snapshot)
        if let activity {
            // The user can swipe the Live Activity away from the Lock Screen
            // mid-session: it leaves `Activity.activities` and its state becomes
            // `.dismissed`/`.ended`, so our cached reference is stale and `update`
            // would silently no-op (leaving us falsely reporting "live" and
            // suppressing the fallback for the rest of the session). Only
            // `.active`/`.stale` are genuinely live; anything else — drop the
            // reference and fall through to re-request a fresh activity.
            if activity.activityState == .active || activity.activityState == .stale {
                let box = SendableActivity(activity)
                Task { await box.value.update(content) }
                return true
            }
            self.activity = nil
        }
        // FIX 1a: before requesting a fresh activity, adopt any already-running one
        // we don't yet track. Push-to-start creates activities OUTSIDE this request
        // path (APNs, no foreground) and `activityUpdates` may not have delivered it
        // to our observer yet — re-scanning here keeps a still-alive background
        // process from `Activity.request`-ing a duplicate on top of the pushed one.
        if adoptRunningActivity() { return true }
        do {
            // May fail if the app is in the background (starting a Live Activity
            // needs the foreground without a push backend) — the fallback
            // notification (and the in-app banner once opened) covers that case.
            activity = try Activity.request(attributes: DiveActivityAttributes(), content: content)
            return true
        } catch {
            log.error("Live Activity start failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Scans `Activity.activities` for a genuinely-live Live Activity we're not yet
    /// tracking (a push-to-start one) and adopts it, refreshing it to the current
    /// snapshot. Returns whether an activity is live afterwards. A no-op that
    /// returns `true` when we already track a live activity.
    @discardableResult
    private func adoptRunningActivity() -> Bool {
        if let activity, activity.activityState == .active || activity.activityState == .stale {
            return true
        }
        guard let existing = Activity<DiveActivityAttributes>.activities.first(where: {
            $0.activityState == .active || $0.activityState == .stale
        }) else { return false }
        adopt(existing)
        return true
    }

    /// Adopts `activity` (from the `activityUpdates` observer or `adoptRunningActivity`)
    /// as the session's Live Activity, unless we already track a live one. A pushed
    /// activity is frozen at its trigger-time content, so we immediately push the
    /// latest snapshot and remove any fallback notification now that a real activity
    /// covers the session.
    private func adopt(_ activity: Activity<DiveActivityAttributes>) {
        guard activity.activityState == .active || activity.activityState == .stale else { return }
        // FIX 1: we already track a genuinely-live activity, so the one arriving here is
        // a duplicate (e.g. a push-to-start activity landing while a locally-requested
        // one is already running). Adopting it would strand the currently-tracked one
        // (two Live Activities for one session); instead END the newcomer and keep ours.
        // BUT: `activityUpdates` re-delivers EVERY newly-started activity — including the
        // one WE just created via `Activity.request` in `updateActivity`. That newcomer
        // IS `self.activity`; ending it here would end our own live activity (churn /
        // re-request loop, and no activity at all in the background). Guard on identity:
        // only end a genuine DIFFERENT duplicate, never our own re-delivered activity.
        if let current = self.activity,
           current.activityState == .active || current.activityState == .stale {
            if activity.id != current.id { end(activity) }  // our own re-delivery: already tracked, no-op
            return
        }
        // FIX 2: an activity arrives but there's no session to back it — the session is
        // already over (e.g. a stale pushed copy landing after the terminal snapshot, or
        // after `dismiss()`). Don't adopt a phantom; END it — unless it's the activity we
        // already track (same id), which `endActivity`/`clear` own and must not be double-
        // ended here. (The init-adoption path is separate: it deliberately keeps an
        // at-launch activity alive under its own grace timer until the first redelivered
        // snapshot, and never routes through here.)
        guard let snapshot else {
            if activity.id != self.activity?.id { end(activity) }
            return
        }
        self.activity = activity
        let box = SendableActivity(activity)
        let content = content(for: snapshot)
        Task { await box.value.update(content) }
        clearNotification(for: snapshot.startTime)
    }

    private func endActivity() {
        guard let activity else { return }
        self.activity = nil
        end(activity)
    }

    /// Ends an arbitrary activity immediately (used for duplicate/phantom activities in
    /// `adopt`, not just the tracked one). `Activity` isn't `Sendable`; box it for the
    /// detached end — `end` is nonisolated and thread-safe.
    private func end(_ activity: Activity<DiveActivityAttributes>) {
        let box = SendableActivity(activity)
        Task { await box.value.end(nil, dismissalPolicy: .immediate) }
    }

    // MARK: - Background start fallbacks (push-to-start + notification)

    /// A Live Activity couldn't be started locally (background, or activities
    /// disabled). Try to surface the session anyway.
    ///
    /// Order: on iOS 17.2+ with a stored push-to-start token, ask the Worker to
    /// APNs-start the Live Activity (auto Dynamic Island, no foreground) — once per
    /// session. If that succeeds, iOS shows the real Live Activity and we skip the
    /// notification. If push isn't possible (older OS / no token yet) or the trigger
    /// fails, fall back to the once-per-session local notification (stage 1).
    private func startInBackground(for snapshot: LiveSessionSnapshot) {
        // Only a fallback for when the app can't show the live banner. If we're
        // foreground-active the user is already watching the in-app banner, and
        // `updateActivity` also returns false while foregrounded when Live
        // Activities are disabled in Settings — starting via push or posting a
        // "open DiveFree" notification then would be redundant. Skip (and don't
        // latch, so a later background snapshot can still act).
        guard UIApplication.shared.applicationState != .active else { return }

        // Push-to-start when available: one APNs attempt per session. On failure we
        // fall through to the notification from inside the task. The latch is
        // marked here (not per-attempt) so we never spam APNs at the snapshot cadence.
        if #available(iOS 17.2, *),
           let credential = PushToStartStore.current(),
           pushLatch.markPosted(for: snapshot.startTime) {
            let pushTrigger = pushTrigger
            // FIX 4: record the attempt as PENDING (accepted: false) BEFORE the request
            // goes on the wire. A snapshot arriving mid-flight (~2 s cadence) then sees a
            // pending push for this session and withholds the fallback notification,
            // instead of racing it onto the pushed Live Activity that's about to appear.
            pushAttempt = (start: snapshot.startTime, at: Date(), accepted: false)
            Task { @MainActor in
                let started = await pushTrigger.trigger(
                    snapshot: snapshot, token: credential.token, env: credential.env
                )
                if started {
                    // 2xx: promote the pending attempt to accepted so the grace window
                    // keeps suppressing the fallback while the pushed activity lands.
                    // FIX 2: guard like the failure branch — if the session ended while the
                    // request was on the wire (`endPushSession` set `pushAttempt = nil`),
                    // do NOT resurrect a grace record for the dead session; leave it nil.
                    if self.pushAttempt?.start == snapshot.startTime {
                        self.pushAttempt = (start: snapshot.startTime, at: Date(), accepted: true)
                    }
                } else {
                    // Trigger failed — clear this session's attempt so the fallback can
                    // post, then post it now.
                    if self.pushAttempt?.start == snapshot.startTime { self.pushAttempt = nil }
                    self.postNotificationIfNeeded(for: snapshot)
                }
            }
            return
        }
        postNotificationIfNeeded(for: snapshot)
    }

    /// Posts the once-per-session fallback notification, latching so the ~2 s
    /// snapshot cadence can't repost it. Requests provisional (silent) permission
    /// lazily here — the first time a notification would actually post, never at
    /// launch — so a reviewer sees no prompt.
    private func postNotificationIfNeeded(for snapshot: LiveSessionSnapshot) {
        // Re-check foregroundedness: `startInBackground` already guards, but a
        // failed push-to-start reaches here from an async task, by which point the
        // user may have opened the app — the in-app banner then covers it, so don't
        // post (and don't latch, so a later background snapshot can still post).
        guard UIApplication.shared.applicationState != .active else { return }
        // FIX 4: within the grace window after a push trigger for THIS session — whether
        // still PENDING (accepted: false, request on the wire) or ACCEPTED (2xx) — the
        // pushed Live Activity is either coming or already arriving (adoption hasn't won
        // yet), so the notification would land on top of it. Suppress in both states,
        // WITHOUT latching, so that once the window passes with still no activity a later
        // snapshot posts the (correct) fallback exactly once.
        if let pushAttempt,
           pushAttempt.start == snapshot.startTime,
           Date().timeIntervalSince(pushAttempt.at) < Self.pushGrace {
            return
        }
        guard notificationLatch.markPosted(for: snapshot.startTime) else { return }
        let id = LiveSessionNotificationLatch.identifier(for: snapshot.startTime)
        let notifier = notifier
        Task {
            await notifier.requestAuthorization()
            notifier.add(
                id: id,
                // Plain `String`s handed to UNMutableNotificationContent — no
                // SwiftUI auto-localization — so localize explicitly.
                title: String(localized: "Dive session running on your watch"),
                body: String(localized: "Open DiveFree to follow it live — depth and dives update in the app.")
            )
        }
    }

    /// Removes the fallback notification for `startTime` and releases the latch.
    ///
    /// Removal is by DERIVED id and UNCONDITIONAL — deliberately NOT gated on the
    /// in-memory latch. iOS can recycle the app between posting the notification
    /// and the terminal snapshot that removes it; that snapshot relaunches us into
    /// a fresh process with an empty latch, so a latch-gated remove would strand
    /// the notification in Notification Center forever. The latch stays purely as
    /// the once-per-post guard. Removing an unknown id is a no-op, so this is
    /// idempotent and safe on the cheap per-snapshot "activity took over" path.
    private func clearNotification(for startTime: Date?) {
        notificationLatch.clear()
        // NB: deliberately does NOT touch `pushLatch` (FIX 3). This runs on every
        // activity-live snapshot; clearing the push latch here would re-push a Live
        // Activity the user swiped away ~2 s later, overriding an explicit dismissal.
        // The push latch is released only when the session ends — see `endPushSession`.
        guard let startTime else { return }
        notifier.remove(id: LiveSessionNotificationLatch.identifier(for: startTime))
    }

    // MARK: - Dismissed-session persistence (FIX 3(b))

    /// `UserDefaults` key for the manually-dismissed session's start time. Persisting
    /// this across launches stops a redelivered `receivedApplicationContext` (WCSession
    /// resends it on every activation) from resurrecting a dismissed banner.
    private static let dismissedStartKey = "liveSession.dismissedStart"

    /// Persists (or clears, on `nil`) the dismissed session's start time. Stored as a
    /// `timeIntervalSince1970` `Double`; sentinel-free — absence of the key means none.
    private static func persistDismissedStart(_ start: Date?) {
        let defaults = UserDefaults.standard
        if let start {
            defaults.set(start.timeIntervalSince1970, forKey: dismissedStartKey)
        } else {
            defaults.removeObject(forKey: dismissedStartKey)
        }
    }

    /// Restores a persisted dismissed start (or `nil` if none was stored).
    private static func loadDismissedStart() -> Date? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: dismissedStartKey) != nil else { return nil }
        return Date(timeIntervalSince1970: defaults.double(forKey: dismissedStartKey))
    }
}

/// Pure once-per-session decision logic for the background fallback notification,
/// kept free of ActivityKit/UNUserNotification so it can be reasoned about (and
/// unit-tested) in isolation. Keyed by the session's `startTime`.
struct LiveSessionNotificationLatch {
    /// Start time of the session we've posted a notification for, if any.
    private(set) var postedStart: Date?

    /// Marks that a notification should post for `startTime`. Returns `true` the
    /// first time for a given session and `false` afterwards, so repeated snapshots
    /// of the same session post exactly once.
    mutating func markPosted(for startTime: Date) -> Bool {
        guard postedStart != startTime else { return false }
        postedStart = startTime
        return true
    }

    /// Resets the once-per-post guard so a future session can post again. Returns
    /// the previously-latched `startTime` (or `nil`); callers no longer use it for
    /// removal — that's keyed off the snapshot's start time so it survives a
    /// process relaunch — but it's kept for tests/introspection.
    @discardableResult
    mutating func clear() -> Date? {
        defer { postedStart = nil }
        return postedStart
    }

    /// Stable notification identifier for a session, derived from its start time so
    /// the post and every remove path address the same request.
    static func identifier(for startTime: Date) -> String {
        "live-session-\(startTime.timeIntervalSince1970)"
    }
}

/// Injectable seam for the fallback notification so the latch and clear paths are
/// testable without the real notification center. All methods are safe to call off
/// the main actor; `UNUserNotificationCenter` is thread-safe.
protocol LiveSessionNotifier: Sendable {
    /// Lazily request provisional (silent) authorization — see `postNotificationIfNeeded`.
    func requestAuthorization() async
    func add(id: String, title: String, body: String)
    func remove(id: String)
}

/// Real `UNUserNotificationCenter`-backed notifier.
struct SystemLiveSessionNotifier: LiveSessionNotifier {
    func requestAuthorization() async {
        // `.provisional` is granted silently (no prompt); notifications land
        // quietly in Notification Center until the user promotes the app.
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.provisional, .alert, .sound])
    }

    func add(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // Deliver immediately (nil trigger); a duplicate id replaces in place.
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func remove(id: String) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }
}

/// Carries an `Activity` reference into a detached task. ActivityKit's `Activity`
/// isn't `Sendable`, but its `update`/`end` are nonisolated and thread-safe, and
/// we hand off ownership on the main actor before firing — so the crossing is safe.
private struct SendableActivity: @unchecked Sendable {
    let value: Activity<DiveActivityAttributes>
    init(_ value: Activity<DiveActivityAttributes>) { self.value = value }
}
