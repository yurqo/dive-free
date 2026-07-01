import Foundation
import Observation
import CoreData
import CloudKit
import os

/// Observes NSPersistentCloudKitContainer's sync events (which back SwiftData's
/// CloudKit mirroring) so the app can show an honest sync status and, crucially,
/// surface the *actual* CloudKit error when sync fails — the diagnostic for
/// "my photos aren't syncing". There is no API to force a pull; this only
/// reflects what CloudKit is doing.
@MainActor
@Observable
final class CloudKitSyncMonitor {
    enum Phase: Equatable { case idle, syncing }

    private(set) var phase: Phase = .idle
    /// End time of the last successful import/export, for "Synced <time> ago".
    private(set) var lastSyncDate: Date?
    /// Message from the last failed sync event — **sticky**: it is NOT cleared by a
    /// later successful event, so a photo-export failure isn't masked when an
    /// unrelated session-export succeeds right after. Cleared only by `clearError()`
    /// (pull-to-refresh) so a resolved problem can clear.
    private(set) var lastError: String?
    private(set) var lastErrorDate: Date?

    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private let log = Logger(subsystem: "org.yurko.divefree", category: "CloudKitSync")

    /// Begins observing sync events (idempotent). The notification is global, so a
    /// container need not be passed in.
    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event else { return }
            // Extract Sendable primitives; the Event itself isn't Sendable.
            let inProgress = event.endDate == nil
            let endDate = event.endDate
            let errorText = event.error.map { Self.describe($0) }
            // Delivered on the main queue, so we're already on the main actor.
            MainActor.assumeIsolated {
                self?.apply(inProgress: inProgress, endDate: endDate, errorText: errorText)
            }
        }
    }

    /// Clears a sticky error so a resolved problem can drop off (pull-to-refresh).
    func clearError() {
        lastError = nil
        lastErrorDate = nil
    }

    private func apply(inProgress: Bool, endDate: Date?, errorText: String?) {
        if inProgress {
            phase = .syncing
            return
        }
        phase = .idle
        if let errorText {
            lastError = errorText
            lastErrorDate = Date()
            log.error("CloudKit sync event failed: \(errorText, privacy: .public)")
        } else if let endDate {
            lastSyncDate = endDate
            // NB: don't clear lastError here — a successful session export must not
            // hide a still-failing photo export.
        }
    }

    /// Turns a CloudKit error into something actionable. For a `partialFailure`
    /// (the common "some records rejected" case — e.g. photo records failing on a
    /// schema gap), the useful detail is per-record, so surface the first
    /// underlying error rather than the generic "error 2".
    nonisolated static func describe(_ error: Error) -> String {
        if let ck = error as? CKError, ck.code == .partialFailure,
           let partials = ck.partialErrorsByItemID, let first = partials.values.first {
            let ns = first as NSError
            return "\(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
        }
        let ns = error as NSError
        return "\(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
    }
}
