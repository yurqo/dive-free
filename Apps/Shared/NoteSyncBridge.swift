import Foundation
import SwiftData
import CoreData
import Domain
import Persistence
import Sync

/// The journal is both a CloudKit merge log and durable WatchConnectivity outbox.
/// Retained by the app/coordinator; remote-store notifications handle iPad edits.
@MainActor final class NoteSyncBridge {
    let store: NoteMutationStore
    let sync: SyncManager
    let directory: URL
    private var observer: NSObjectProtocol?
    private var saveObserver: NSObjectProtocol?
    private var timer: Timer?
    private let ackKey = "acknowledgedNoteMutations"
    private var acknowledged: Set<String>

    init(context: ModelContext, sync: SyncManager, directory: URL) {
        self.store = NoteMutationStore(context: context); self.sync = sync; self.directory = directory
        acknowledged = Set(UserDefaults.standard.stringArray(forKey: ackKey) ?? [])
        sync.onNoteTransportReady = { [weak self] in Task { @MainActor in self?.flush() } }
        sync.onReceiveNoteMutation = { [weak self] mutation in
            Task { @MainActor in
                guard let self else { return }
                do {
                    try self.store.receive(mutation)
                    self.markAcknowledged(mutation.id)
                    self.cleanup()
                    self.sync.acknowledgeNoteMutation(mutation.id)
                } catch { self.store.context.rollback() }
            }
        }
        sync.onNoteMutationAcknowledged = { [weak self] id in
            Task { @MainActor in self?.markAcknowledged(id) }
        }
        observer = NotificationCenter.default.addObserver(forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.flush() }
        }
        saveObserver = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.flush() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flush() }
        }
        flush()
    }
    private func markAcknowledged(_ id: UUID) {
        acknowledged.insert(id.uuidString)
        UserDefaults.standard.set(Array(acknowledged), forKey: ackKey)
    }
    func flush() {
        do {
            try store.reconcile()
            cleanup()
            for mutation in try store.all() where !acknowledged.contains(mutation.id.uuidString) {
                sync.sendNoteMutation(mutation)
            }
        } catch { /* Journal persists; retry at the next save/activation/timer. */ }
    }
    func cleanup() {
        for name in (try? store.removedAudioNames()) ?? [] where name == URL(fileURLWithPath: name).lastPathComponent {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
