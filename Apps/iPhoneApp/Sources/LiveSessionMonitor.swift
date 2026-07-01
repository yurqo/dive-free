import Foundation
import os
import Observation
import ActivityKit
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
@MainActor
@Observable
final class LiveSessionMonitor {
    /// The live session to display, or nil when none is active/shown.
    private(set) var snapshot: LiveSessionSnapshot?

    /// Real-time Watch reachability (WCSession). The primary disconnect signal —
    /// combined with snapshot staleness it drives the "reconnecting" treatment.
    private(set) var isReachable = true

    /// Start time of a session the user manually dismissed — ignore further
    /// snapshots for it so a queued/stale update can't bring it back.
    @ObservationIgnored private var dismissedStart: Date?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var activity: Activity<DiveActivityAttributes>?
    @ObservationIgnored private let log = Logger(subsystem: "org.yurko.divefree", category: "LiveSession")

    init() {
        // Adopt an activity that outlived a previous launch so we can update/end it.
        activity = Activity<DiveActivityAttributes>.activities.first
    }

    /// Applies an incoming snapshot: end on the terminal one, otherwise show and
    /// update (unless the user dismissed this exact session).
    func ingest(_ snapshot: LiveSessionSnapshot) {
        guard snapshot.isActive else { clear(); return }
        if let dismissedStart, snapshot.startTime == dismissedStart { return }
        dismissedStart = nil
        self.snapshot = snapshot
        updateActivity(with: snapshot)
        startWatchdog()
    }

    /// Updates real-time reachability and reflects it in the Live Activity at once
    /// (the banner reacts via `@Observable`). This is the fast disconnect path —
    /// no waiting on the staleness backstop.
    func setReachable(_ reachable: Bool) {
        guard reachable != isReachable else { return }
        isReachable = reachable
        if let snapshot { refreshActivity(with: snapshot) }
    }

    /// Combined disconnect state for the UI: unreachable now, or data gone stale.
    func isDisconnected(asOf now: Date = Date()) -> Bool {
        !isReachable || (snapshot?.isStale(asOf: now) ?? false)
    }

    /// Manual phone-side stop for when no "ended" will arrive (Watch battery died
    /// / permanently out of range). Clears the display and blocks resurrection of
    /// the same session; a genuinely new session (different start) still shows.
    func dismiss() {
        dismissedStart = snapshot?.startTime
        snapshot = nil
        endActivity()
        watchdog?.cancel()
        watchdog = nil
    }

    /// Session ended cleanly, expired, or nothing to show — tear everything down.
    private func clear() {
        dismissedStart = nil
        snapshot = nil
        endActivity()
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
                if let snapshot = self.snapshot, snapshot.isExpired() { self.clear(); return }
            }
        }
    }

    // MARK: - Live Activity

    private func content(for snapshot: LiveSessionSnapshot) -> ActivityContent<DiveActivityAttributes.ContentState> {
        // Unreachable → mark stale immediately so the Live Activity shows the
        // "reconnecting" (grayed) treatment in real time; else the staleness backstop.
        let staleDate = isReachable ? snapshot.updatedAt.addingTimeInterval(LiveSessionSnapshot.staleThreshold) : Date()
        return ActivityContent(state: .init(snapshot: snapshot), staleDate: staleDate)
    }

    /// Pushes fresh content to an *existing* activity (used when only reachability
    /// changed — never starts a new activity).
    private func refreshActivity(with snapshot: LiveSessionSnapshot) {
        guard let activity else { return }
        let box = SendableActivity(activity)
        let content = content(for: snapshot)
        Task { await box.value.update(content) }
    }

    private func updateActivity(with snapshot: LiveSessionSnapshot) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let content = content(for: snapshot)
        if let activity {
            let box = SendableActivity(activity)
            Task { await box.value.update(content) }
        } else {
            do {
                // May fail if the app is in the background (starting a Live Activity
                // needs the foreground without a push backend) — the in-app banner
                // still covers that case.
                activity = try Activity.request(attributes: DiveActivityAttributes(), content: content)
            } catch {
                log.error("Live Activity start failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func endActivity() {
        guard let activity else { return }
        self.activity = nil
        let box = SendableActivity(activity)
        Task { await box.value.end(nil, dismissalPolicy: .immediate) }
    }
}

/// Carries an `Activity` reference into a detached task. ActivityKit's `Activity`
/// isn't `Sendable`, but its `update`/`end` are nonisolated and thread-safe, and
/// we hand off ownership on the main actor before firing — so the crossing is safe.
private struct SendableActivity: @unchecked Sendable {
    let value: Activity<DiveActivityAttributes>
    init(_ value: Activity<DiveActivityAttributes>) { self.value = value }
}
