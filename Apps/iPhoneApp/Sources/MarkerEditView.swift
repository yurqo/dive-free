import SwiftUI
import SwiftData
import PhotosUI
import Photos
import UIKit
import Domain
import Persistence

/// Edit a marker on the phone (#143): change its type (icon/label) and note, and
/// attach/detach photos — from the session's existing photos or the library.
struct MarkerEditView: View {
    @Bindable var marker: MarkerRecord
    let session: SessionRecord
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \CustomMarkerRecord.createdAt) private var customKinds: [CustomMarkerRecord]
    @State private var libraryItems: [PhotosPickerItem] = []
    @State private var showAttachExisting = false
    @State private var loaded = false
    @State private var title = ""
    @State private var description = ""
    @State private var kindID = ""
    @State private var transcript = ""
    @State private var summary = ""
    @State private var original: [String: String] = [:]
    @State private var photoIDs: Set<UUID> = []
    @State private var originalPhotoIDs: Set<UUID> = []
    @State private var removedAudio = false
    @State private var confirmDelete = false
    @State private var confirmRemove = false
    @State private var languages: [Locale] = []
    @State private var languageID = Bundle.main.preferredLocalizations.first ?? "en"
    @AppStorage("noteTranscriptionLanguage") private var savedLanguageID = ""
    @State private var processing: Task<Void, Never>?
    @State private var busy = false
    @State private var error: String?
    @State private var suggestion: NoteSummary?
    @State private var reviewTranscript: String?
    var transcriber: any NoteTranscribing = NoteSpeechService()
    var summariser: any NoteSummarising = AppleNoteSummariser()

    private var kinds: [MarkerKind] {
        var result = EventKind.builtInMarkerKinds + customKinds.map { $0.toMarkerKind() }
        if marker.modelContext != nil {
            let originalKind = marker.toDomain().kind
            if !result.contains(where: { $0.id == originalKind.id }) { result.append(originalKind) }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Type") {
                    Picker("Type", selection: kindBinding) {
                        ForEach(kinds) { kind in
                            Text("\(kind.emoji)  \(kind.label)").tag(kind.id)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }
                Section("Note") {
                    TextField("Title", text: $title).accessibilityIdentifier("note.title")
                    TextField("Description", text: $description, axis: .vertical).lineLimit(4...12)
                }
                audioSection
                if busy {
                    Section {
                        ProgressView("Processing on this device…")
                        Button("Cancel Processing") { processing?.cancel() }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
                if let review = reviewTranscript {
                    Section("Review Transcript") {
                        Text(review)
                        Button(description.isEmpty ? "Use as Description" : "Replace Description") { description = review; transcript = review; reviewTranscript = nil }
                        if !description.isEmpty {
                            Button("Append to Description") { description += "\n\n" + review; transcript = review; reviewTranscript = nil }
                        }
                        Button("Keep Transcript Only") { transcript = review; reviewTranscript = nil }
                        Button("Discard Transcription", role: .cancel) { reviewTranscript = nil }
                    }
                }
                if !transcript.isEmpty {
                    Section("Transcript") {
                        Text(transcript)
                        if let reason = summariser.unavailableReason(locale: Locale(identifier: languageID)) { Text(reason).font(.caption) }
                        else { Button("Summarise") { process { suggestion = try await summariser.summarise(transcript, locale: Locale(identifier: languageID)) } }.disabled(busy) }
                    }
                }
                if let suggestion {
                    Section("Review Summary") {
                        Text(suggestion.title).font(.headline)
                        Text(suggestion.text)
                        Button("Use Title and Summary") { title = suggestion.title; summary = suggestion.text; description = suggestion.text; self.suggestion = nil }
                        Button("Discard Summary", role: .cancel) { self.suggestion = nil }
                    }
                }
                if !summary.isEmpty { Section("Saved Summary") { Text(summary) } }
                photosSection
                Button("Delete Note", role: .destructive) { confirmDelete = true }.disabled(busy || marker.modelContext == nil)
            }
            .navigationTitle("Edit Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(busy || marker.modelContext == nil)
                }
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { if !loaded { load(); loaded = true } }
            .onDisappear { processing?.cancel() }
            .onChange(of: marker.modelContext != nil ? marker.audioData?.count : nil, initial: true) { _, _ in
                guard marker.modelContext != nil, let name = marker.audioFileName,
                      let data = marker.audioData else { return }
                if VoiceNoteStore.materialize(data, as: name) {
                    NotificationCenter.default.post(name: .voiceNoteReceived, object: nil)
                }
            }
            .task {
                let supported = await transcriber.languages()
                guard !Task.isCancelled else { return }
                languages = supported
                if let selected = NoteTranscriptionLocale.select(from: supported, savedIdentifier: savedLanguageID) {
                    languageID = selected.identifier
                }
            }
            .confirmationDialog("Delete this note and its recording?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete Note", role: .destructive) { deleteNote() }
            }
            .confirmationDialog("Remove the recording? Your text will be kept.", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove Recording", role: .destructive) { removedAudio = true }
            }
            .sheet(isPresented: $showAttachExisting) {
                AttachExistingPhotosView(session: session, selectedIDs: $photoIDs)
            }
        }
    }

    private var kindBinding: Binding<String> { $kindID }
    private var languageBinding: Binding<String> {
        Binding(get: { languageID }, set: { languageID = $0; savedLanguageID = $0 })
    }

    private func load() {
        photoIDs = Set((marker.photos ?? []).map(\.id)); originalPhotoIDs = photoIDs
        title = marker.title ?? ""; description = marker.text ?? ""; kindID = marker.kind
        transcript = marker.transcript ?? ""; summary = marker.summary ?? ""
        original = ["title": title, "text": description, "transcript": transcript, "summary": summary, "kind": kindID]
    }
    private func save() {
        guard marker.modelContext != nil else { error = String(localized: "This note has been deleted."); return }
        var changes = ["title": title, "text": description, "transcript": transcript, "summary": summary, "kind": kindID].filter { original[$0.key] != $0.value }
        if changes["kind"] != nil, let kind = kinds.first(where: { $0.id == kindID }) { changes["emoji"] = kind.emoji; changes["label"] = kind.label }
        if removedAudio { changes["removeAudio"] = marker.audioFileName ?? "" }
        do {
            for photo in session.photos ?? [] {
                if photoIDs.contains(photo.id) && !originalPhotoIDs.contains(photo.id) { photo.marker = marker }
                if originalPhotoIDs.contains(photo.id) && !photoIDs.contains(photo.id) && photo.marker?.id == marker.id { photo.marker = nil }
            }
            try NoteMutationStore(context: modelContext).save(marker: marker, changes: changes)
            try modelContext.save()
            if libraryItems.isEmpty { dismiss() }
            else {
                busy = true
                Task { await addFromLibrary(libraryItems); busy = false; dismiss() }
            }
        } catch { modelContext.rollback(); self.error = error.localizedDescription }
    }
    private func deleteNote() {
        guard marker.modelContext != nil else { dismiss(); return }
        do {
            try NoteMutationStore(context: modelContext).save(marker: marker, changes: ["delete": "true", "removeAudio": marker.audioFileName ?? ""])
            dismiss()
        } catch { modelContext.rollback(); self.error = error.localizedDescription }
    }
    private func process(_ operation: @escaping @MainActor () async throws -> Void) {
        busy = true; error = nil
        processing = Task { @MainActor in
            defer { busy = false; processing = nil }
            do { try await operation() }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
    @ViewBuilder private var audioSection: some View {
        if marker.modelContext != nil, let name = marker.audioFileName, !removedAudio {
            Section("Recording") {
                VoiceNotePlayButton(fileName: name)
                if languages.isEmpty { Text("On-device transcription is unavailable. You can still edit the description.").font(.caption) }
                else {
                    Picker("Language", selection: languageBinding) {
                        if !languages.contains(where: { $0.identifier == languageID }) {
                            Text(Locale.current.localizedString(forIdentifier: languageID) ?? languageID).tag(languageID)
                        }
                        ForEach(languages, id: \.identifier) { language in
                            Text(Locale.current.localizedString(forIdentifier: language.identifier) ?? language.identifier).tag(language.identifier)
                        }
                    }
                    if !languages.contains(where: { $0.identifier == languageID }) {
                        Text("Choose a supported language to transcribe this recording.").font(.caption)
                    }
                    Button("Transcribe") {
                        process {
                            if let data = marker.audioData { VoiceNoteStore.materialize(data, as: name) }
                            guard VoiceNoteStore.exists(name) else { error = String(localized: "The recording has not downloaded yet. Try again after syncing."); return }
                            reviewTranscript = try await transcriber.transcribe(url: VoiceNoteStore.url(for: name), locale: Locale(identifier: languageID))
                        }
                    }.disabled(busy || !languages.contains(where: { $0.identifier == languageID }))
                }
                Button("Remove Recording", role: .destructive) { confirmRemove = true }.disabled(busy)
            }
        }
    }

    @ViewBuilder private var photosSection: some View {
        Section("Photos") {
            if !photoIDs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach((session.photos ?? []).filter { photoIDs.contains($0.id) }.sorted { $0.createdAt < $1.createdAt }) { photo in
                            PhotoThumbnail(photo: photo)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
            Button { showAttachExisting = true } label: {
                Label("Attach from This Session", systemImage: "photo.stack")
            }
            if !libraryItems.isEmpty { Text("Selected photos will be added when you save.").font(.caption) }
            PhotosPicker(selection: $libraryItems, matching: .images, photoLibrary: .shared()) {
                Label("Add from Library", systemImage: "photo.on.rectangle")
            }
        }
    }

    /// Imports library photos straight onto this marker (added to the session and
    /// linked to the marker), mirroring the gallery's reference-based import (#141).
    private func addFromLibrary(_ items: [PhotosPickerItem]) async {
        var identifiers: [String] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else { continue }
            guard marker.modelContext != nil, session.modelContext != nil else { return }
            let thumb = PhotoStore.saveThumbnail(image)
            modelContext.insert(PhotoRecord(
                assetIdentifier: item.itemIdentifier,
                thumbnailFileName: thumb?.fileName,
                thumbnailData: thumb?.data,
                assetCloudIdentifier: PhotoLibrary.cloudIdentifier(for: item.itemIdentifier),
                session: session,
                marker: marker
            ))
            if let id = item.itemIdentifier { identifiers.append(id) }
        }
        try? modelContext.save()
        mirrorSessionMedia(identifiers, session: session, in: modelContext)
    }
}

/// A grid of the session's photos; tap to link/unlink each to the marker (#143).
struct AttachExistingPhotosView: View {
    let session: SessionRecord
    @Binding var selectedIDs: Set<UUID>
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 88), spacing: 8)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach((session.photos ?? []).sorted { $0.createdAt < $1.createdAt }) { photo in
                        Button { toggle(photo) } label: {
                            PhotoThumbnail(photo: photo)
                                .overlay(alignment: .topTrailing) {
                                    if isLinked(photo) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.white, .blue)
                                            .padding(4)
                                    }
                                }
                                .overlay {
                                    if isLinked(photo) {
                                        RoundedRectangle(cornerRadius: 8).strokeBorder(.blue, lineWidth: 3)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .navigationTitle("Attach Photos")
            .navigationBarTitleDisplayMode(.inline)
            .overlay {
                if (session.photos ?? []).isEmpty {
                    ContentUnavailableView("No Photos", systemImage: "photo", description: Text("Add photos to this dive first."))
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func isLinked(_ photo: PhotoRecord) -> Bool {
        selectedIDs.contains(photo.id)
    }

    private func toggle(_ photo: PhotoRecord) {
        if isLinked(photo) { selectedIDs.remove(photo.id) } else { selectedIDs.insert(photo.id) }
    }
}
