import SwiftUI
import SwiftData
import Domain
import Persistence

struct WatchNoteEditView: View {
    let marker: MarkerRecord
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var custom: [CustomMarkerRecord]
    @State private var loaded = false
    @State private var title = ""
    @State private var kindID = ""
    @State private var originalTitle = ""
    @State private var originalKind = ""
    @State private var remove = false
    @State private var confirmRemove = false
    @State private var confirmDelete = false
    @State private var error: String?
    private var kinds: [MarkerKind] {
        var result = EventKind.builtInMarkerKinds + custom.map { $0.toMarkerKind() }
        if marker.modelContext != nil {
            let kind = marker.toDomain().kind
            if !result.contains(where: { $0.id == kind.id }) { result.append(kind) }
        }
        return result
    }
    var body: some View {
        Form {
            TextField("Title", text: $title)
            Picker("Type", selection: $kindID) {
                ForEach(kinds) { Text("\($0.emoji) \($0.label)").tag($0.id) }
            }
            if marker.modelContext != nil && marker.audioFileName != nil && !remove {
                Button("Remove Recording", role: .destructive) { confirmRemove = true }
            }
            if let error { Text(error).foregroundStyle(.red) }
            Button("Save") { save() }
            Button("Cancel") { dismiss() }
            Button("Delete Note", role: .destructive) { confirmDelete = true }
        }
        .navigationTitle("Edit Note")
        .onAppear {
            guard !loaded, marker.modelContext != nil else { return }
            loaded = true
            title = marker.title ?? ""; kindID = marker.kind
            originalTitle = title; originalKind = kindID
        }
        .confirmationDialog("Remove the recording?", isPresented: $confirmRemove) {
            Button("Remove Recording", role: .destructive) { remove = true }
        }
        .confirmationDialog("Delete this note?", isPresented: $confirmDelete) {
            Button("Delete Note", role: .destructive) { commit(["delete": "true", "removeAudio": marker.audioFileName ?? ""]) }
        }
    }
    private func save() {
        var changes: [String: String] = [:]
        if title != originalTitle { changes["title"] = title }
        if kindID != originalKind, let kind = kinds.first(where: { $0.id == kindID }) {
            changes.merge(["kind": kind.id, "emoji": kind.emoji, "label": kind.label]) { _, new in new }
        }
        if remove { changes["removeAudio"] = marker.audioFileName ?? "" }
        commit(changes)
    }
    private func commit(_ changes: [String: String]) {
        guard marker.modelContext != nil else { dismiss(); return }
        do { try NoteMutationStore(context: context).save(marker: marker, changes: changes); dismiss() }
        catch { context.rollback(); self.error = error.localizedDescription }
    }
}

struct WatchNotesList: View {
    let sessionID: UUID
    @Query private var records: [SessionRecord]
    init(sessionID: UUID) {
        self.sessionID = sessionID
        _records = Query(filter: #Predicate<SessionRecord> { $0.id == sessionID })
    }
    var body: some View {
        VStack {
            ForEach((records.first?.markers ?? []).sorted { $0.timestamp < $1.timestamp }) { marker in
                NavigationLink { WatchNoteEditView(marker: marker) } label: {
                    Text("\(marker.toDomain().kind.emoji) \(marker.toDomain().displayTitle)")
                }
            }
        }
    }
}
