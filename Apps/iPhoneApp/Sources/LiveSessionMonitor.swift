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
/// when the first snapshot of a session arrives and no activity starts, we post a
/// single local notification ("session running on your watch"). Tapping it opens
/// the app; the next per-snapshot retry then starts the real Live Activity and the
/// notification is removed. The notification is likewise removed when the session
/// ends, is dismissed, or the activity otherwise takes over.
@MainActor
@Observable
final class LiveSessionMonitor {
    /// The live session to display, or nil when none is active/shown.
    private(set) var snapshot: LiveSessionSnapshot?

    /// Start time of a session the user manually dismissed — ignore further
    /// snapshots for it so a queued/stale update can't bring it back.
    @ObservationIgnored private var dismissedStart: Date?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var activity: Activity<DiveActivityAttributes>?
    /// Once-per-session latch for the background fallback notification.
    @ObservationIgnored private var notificationLatch = LiveSessionNotificationLatch()
    @ObservationIgnored private let notifier: LiveSessionNotifier
    @ObservationIgnored private let log = Logger(subsystem: "org.yurko.divefree", category: "LiveSession")

    init(notifier: LiveSessionNotifier = SystemLiveSessionNotifier()) {
        self.notifier = notifier
        // Adopt an activity that outlived a previous launch so we can update/end it.
        activity = Activity<DiveActivityAttributes>.activities.first
    }

    /// Applies an incoming snapshot: end on the terminal one, otherwise show and
    /// update (unless the user dismissed this exact session).
    func ingest(_ snapshot: LiveSessionSnapshot) {
        // Terminal snapshot: tear down and remove this session's fallback
        // notification by its own start time (the latch may be empty after a
        // background relaunch — see `clearNotification(for:)`).
        guard snapshot.isActive else { clear(notificationStart: snapshot.startTime); return }
        if let dismissedStart, snapshot.startTime == dismissedStart { return }
        dismissedStart = nil
        self.snapshot = snapshot
        // If a Live Activity is (or just became) live, it covers the session and
        // any earlier fallback notification is removed; otherwise — background or
        // activities disabled — post the once-per-session notification instead.
        if updateActivity(with: snapshot) {
            clearNotification(for: snapshot.startTime)
        } else {
            postNotificationIfNeeded(for: snapshot)
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
        watchdog?.cancel()
        watchdog = nil
    }

    /// Session ended cleanly, expired, or nothing to show — tear everything down,
    /// removing the fallback notification for `notificationStart` (the terminal
    /// snapshot's start time, or the current snapshot's on the watchdog path).
    private func clear(notificationStart: Date?) {
        dismissedStart = nil
        snapshot = nil
        endActivity()
        clearNotification(for: notificationStart)
        watchdog?.cancel()
        watchdog = nil
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

    private func endActivity() {
        guard let activity else { return }
        self.activity = nil
        let box = SendableActivity(activity)
        Task { await box.value.end(nil, dismissalPolicy: .immediate) }
    }

    // MARK: - Background fallback notification

    /// Posts the once-per-session fallback notification, latching so the ~2 s
    /// snapshot cadence can't repost it. Requests provisional (silent) permission
    /// lazily here — the first time a notification would actually post, never at
    /// launch — so a reviewer sees no prompt.
    private func postNotificationIfNeeded(for snapshot: LiveSessionSnapshot) {
        // Only a fallback for when the app can't show the live banner. If we're
        // foreground-active the user is already watching the in-app banner, and
        // `updateActivity` also returns false while foregrounded when Live
        // Activities are disabled in Settings — posting "open DiveFree to follow
        // it live" then would fire on top of the screen they're looking at. Skip
        // (and don't latch, so a later background snapshot can still post).
        guard UIApplication.shared.applicationState != .active else { return }
        guard notificationLatch.markPosted(for: snapshot.startTime) else { return }
        let id = LiveSessionNotificationLatch.identifier(for: snapshot.startTime)
        let notifier = notifier
        Task {
            await notifier.requestAuthorization()
            notifier.add(
                id: id,
                title: "Dive session running on your watch",
                body: "Open DiveFree to follow it live — depth and dives update in the app."
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
        guard let startTime else { return }
        notifier.remove(id: LiveSessionNotificationLatch.identifier(for: startTime))
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
