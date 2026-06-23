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

    private var kinds: [MarkerKind] { EventKind.builtInMarkerKinds + customKinds.map { $0.toMarkerKind() } }

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
                    TextField("Note", text: noteBinding, axis: .vertical).lineLimit(1...4)
                }
                photosSection
            }
            .navigationTitle("Edit Marker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { try? modelContext.save(); dismiss() }
                }
            }
            .sheet(isPresented: $showAttachExisting) {
                AttachExistingPhotosView(session: session, marker: marker)
            }
            .onChange(of: libraryItems) { _, items in
                guard !items.isEmpty else { return }
                Task { await addFromLibrary(items); libraryItems = [] }
            }
        }
    }

    private var kindBinding: Binding<String> {
        Binding(
            get: { marker.kind },
            set: { id in
                guard let kind = kinds.first(where: { $0.id == id }) else { return }
                marker.kind = kind.id
                marker.emoji = kind.emoji
                marker.label = kind.label
            }
        )
    }

    private var noteBinding: Binding<String> {
        Binding(get: { marker.text ?? "" }, set: { marker.text = $0.isEmpty ? nil : $0 })
    }

    @ViewBuilder private var photosSection: some View {
        Section("Photos") {
            if !marker.photos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(marker.photos.sorted { $0.createdAt < $1.createdAt }) { photo in
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
            let thumbnailFileName = PhotoStore.saveThumbnail(image)
            modelContext.insert(PhotoRecord(
                assetIdentifier: item.itemIdentifier,
                thumbnailFileName: thumbnailFileName,
                session: session,
                marker: marker
            ))
            if let id = item.itemIdentifier { identifiers.append(id) }
        }
        try? modelContext.save()
        Task { await PhotoAlbum.mirror(assetIdentifiers: identifiers, sessionAlbumTitle: nil) }
    }
}

/// A grid of the session's photos; tap to link/unlink each to the marker (#143).
struct AttachExistingPhotosView: View {
    let session: SessionRecord
    let marker: MarkerRecord
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 88), spacing: 8)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(session.photos.sorted { $0.createdAt < $1.createdAt }) { photo in
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
                if session.photos.isEmpty {
                    ContentUnavailableView("No Photos", systemImage: "photo", description: Text("Add photos to this dive first."))
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { try? modelContext.save(); dismiss() }
                }
            }
        }
    }

    private func isLinked(_ photo: PhotoRecord) -> Bool {
        photo.marker?.persistentModelID == marker.persistentModelID
    }

    private func toggle(_ photo: PhotoRecord) {
        photo.marker = isLinked(photo) ? nil : marker
    }
}
