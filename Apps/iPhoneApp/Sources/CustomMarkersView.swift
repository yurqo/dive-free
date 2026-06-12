import SwiftUI
import SwiftData
import Persistence
import Sync

/// Environment access to the shared `SyncManager` (not `@Observable`, so it can't
/// use `.environment(_:)` object injection — use a key instead).
private struct SyncManagerKey: EnvironmentKey {
    static let defaultValue: SyncManager? = nil
}

extension EnvironmentValues {
    var syncManager: SyncManager? {
        get { self[SyncManagerKey.self] }
        set { self[SyncManagerKey.self] = newValue }
    }
}

/// Manage user-defined custom markers (emoji + label). Changes are persisted and
/// pushed to the Watch so they appear in the in-dive marker carousel.
struct CustomMarkersView: View {
    @Query(sort: \CustomMarkerRecord.createdAt) private var markers: [CustomMarkerRecord]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.syncManager) private var sync

    @State private var newEmoji = ""
    @State private var newLabel = ""

    private var trimmedLabel: String { newLabel.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedEmoji: String { newEmoji.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Form {
            Section("Add Marker") {
                TextField("Emoji", text: $newEmoji)
                TextField("Label", text: $newLabel)
                Button("Add", action: add)
                    .disabled(trimmedEmoji.isEmpty || trimmedLabel.isEmpty)
            }

            Section("Your Markers") {
                if markers.isEmpty {
                    Text("No custom markers yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(markers) { marker in
                        HStack(spacing: 12) {
                            Text(marker.emoji)
                            Text(marker.label)
                        }
                    }
                    .onDelete(perform: delete)
                }
            }
        }
        .navigationTitle("Custom Markers")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func add() {
        guard !trimmedEmoji.isEmpty, !trimmedLabel.isEmpty else { return }
        modelContext.insert(CustomMarkerRecord(emoji: trimmedEmoji, label: trimmedLabel))
        try? modelContext.save()
        newEmoji = ""
        newLabel = ""
        pushToWatch()
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(markers[index])
        }
        try? modelContext.save()
        pushToWatch()
    }

    /// Sends the freshly-fetched list (the `@Query` hasn't refreshed yet within
    /// this call) to the Watch.
    private func pushToWatch() {
        let descriptor = FetchDescriptor<CustomMarkerRecord>(sortBy: [SortDescriptor(\.createdAt)])
        let current = (try? modelContext.fetch(descriptor)) ?? []
        sync?.sendCustomMarkers(current.map { $0.toMarkerKind() })
    }
}
