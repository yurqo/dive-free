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
    /// Message from the last failed sync event, or nil once a later event succeeds.
    private(set) var lastError: String?

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
            let recoverable = event.error.map { Self.isRecoverable($0) } ?? false
            // Delivered on the main queue, so we're already on the main actor.
            MainActor.assumeIsolated {
                self?.apply(inProgress: inProgress, endDate: endDate, errorText: errorText, recoverable: recoverable)
            }
        }
    }

    private func apply(inProgress: Bool, endDate: Date?, errorText: String?, recoverable: Bool) {
        if inProgress {
            phase = .syncing
            return
        }
        phase = .idle
        if let errorText, !recoverable {
            // A genuine, actionable failure — surface it and log the detail.
            lastError = errorText
            log.error("CloudKit sync failed: \(errorText, privacy: .public)")
        } else if let errorText {
            // Transient / auto-recovered (change-token expiry, network, rate-limit,
            // busy zone…). NSPersistentCloudKitContainer retries on its own, so we
            // don't raise a red "Sync error" — leave the last-good state in place.
            log.notice("CloudKit sync recoverable event (auto-retry): \(errorText, privacy: .public)")
        } else if let endDate {
            lastSyncDate = endDate
            lastError = nil
        }
    }

    /// Turns a CloudKit error into something actionable. For a `partialFailure`
    /// (the "some records/zones rejected" case) the useful detail is in the
    /// per-item/zone sub-errors, so recurse into the first; also unwraps a wrapped
    /// underlying error rather than reporting the generic outer "error 2".
    nonisolated static func describe(_ error: Error) -> String {
        if let ck = error as? CKError, ck.code == .partialFailure,
           let first = ck.partialErrorsByItemID?.values.first {
            return describe(first)
        }
        let ns = error as NSError
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
            return describe(underlying)
        }
        return "\(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
    }

    /// Whether an error is transient and auto-recovered by
    /// NSPersistentCloudKitContainer (network blips, rate limits, a busy zone, or
    /// an expired change token — "client knowledge differs from server knowledge").
    /// These resolve on the framework's own retry, so we don't flag them as a
    /// failure (they were showing up as a false "Sync error").
    nonisolated static func isRecoverable(_ error: Error) -> Bool {
        if let ck = error as? CKError {
            switch ck.code {
            case .networkUnavailable, .networkFailure, .serviceUnavailable,
                 .requestRateLimited, .zoneBusy, .changeTokenExpired, .serverResponseLost:
                return true
            case .partialFailure:
                guard let partials = ck.partialErrorsByItemID, !partials.isEmpty else { return false }
                return partials.values.allSatisfy { isRecoverable($0) }
            default:
                return false
            }
        }
        let ns = error as NSError
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
            return isRecoverable(underlying)
        }
        return false
    }
}
