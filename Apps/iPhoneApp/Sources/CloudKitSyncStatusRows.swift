import SwiftUI

/// Reusable CloudKit sync-status rows — used in Settings ▸ iCloud and on the
/// session detail. Shows Syncing… / Last synced / the last Sync error with the
/// actual CKError detail (the diagnostic for cross-device sync). Place inside a
/// `Section`/`Form`.
struct CloudKitSyncStatusRows: View {
    @Environment(CloudKitSyncMonitor.self) private var cloudSync

    var body: some View {
        if let error = cloudSync.lastError {
            LabeledContent("Status") {
                Label("Sync error", systemImage: "exclamationmark.icloud").foregroundStyle(.red)
            }
            Text(error)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let last = cloudSync.lastSyncDate {
                LabeledContent("Last synced", value: last.formatted(.relative(presentation: .named)))
            }
        } else if cloudSync.phase == .syncing {
            LabeledContent("Status") {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Syncing…") }
            }
        } else if let last = cloudSync.lastSyncDate {
            LabeledContent("Last synced", value: last.formatted(.relative(presentation: .named)))
        } else {
            LabeledContent("Status", value: "Idle")
        }
    }
}
