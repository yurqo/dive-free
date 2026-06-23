import SwiftUI
import PhotosUI
import Photos
import UIKit
import Persistence

/// A photo as handed to the owner to persist: a library reference (when one was
/// obtained) plus a thumbnail to cache for offline display (#141). Full images are
/// not copied — they stay in the Photos library.
struct ImportedPhoto {
    let assetIdentifier: String?
    let thumbnail: UIImage
}

/// A reusable "Photos" section: a thumbnail strip + add-from-library / take-photo
/// (plus any `extraActions` the owner adds), with full-screen view and delete. The
/// owner supplies the photos and the add/delete side effects.
struct PhotoGallerySection<Extra: View>: View {
    let photos: [PhotoRecord]
    let onAdd: (ImportedPhoto) -> Void
    let onDelete: (PhotoRecord) -> Void
    @ViewBuilder var extraActions: Extra

    @State private var libraryItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var fullScreen: PhotoRecord?

    var body: some View {
        Section("Photos") {
            if !photos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(photos) { photo in
                            PhotoThumbnail(photo: photo)
                                .onTapGesture { fullScreen = photo }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
            // .shared() makes the picked item's `itemIdentifier` a library asset id
            // we can reference later, instead of an opaque copy.
            PhotosPicker(selection: $libraryItem, matching: .images, photoLibrary: .shared()) {
                Label("Add from Library", systemImage: "photo.on.rectangle")
            }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { showCamera = true } label: { Label("Take Photo", systemImage: "camera") }
            }
            extraActions
        }
        .onChange(of: libraryItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    onAdd(ImportedPhoto(assetIdentifier: item.itemIdentifier, thumbnail: image))
                }
                libraryItem = nil
            }
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker { image in
                // Save the capture to Photos so it can be referenced like any other
                // library asset; fall back to a thumbnail-only record if denied.
                Task { onAdd(ImportedPhoto(assetIdentifier: await PhotoLibrary.save(image), thumbnail: image)) }
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(item: $fullScreen) { photo in
            FullScreenPhotoView(photo: photo) { onDelete(photo) }
        }
    }
}

/// Photos attached to a session, plus the timestamp auto-suggest (#126).
struct SessionPhotosSection: View {
    let session: SessionRecord
    @Environment(\.modelContext) private var modelContext
    @State private var suggestions: [PHAsset] = []
    @State private var showSuggestions = false
    @State private var showPermissionAlert = false
    @State private var showNoMatches = false

    var body: some View {
        PhotoGallerySection(
            photos: session.photos.sorted { $0.createdAt < $1.createdAt },
            onAdd: { save(assetIdentifier: $0.assetIdentifier, thumbnail: $0.thumbnail) },
            onDelete: { remove($0) }
        ) {
            Button { Task { await suggest() } } label: {
                Label("Suggest from This Dive", systemImage: "wand.and.stars")
            }
        }
        .sheet(isPresented: $showSuggestions) {
            PhotoSuggestionsView(assets: suggestions) { assets in
                Task { await importAssets(assets) }
                showSuggestions = false
            }
        }
        .alert("Photo Access Needed", isPresented: $showPermissionAlert) {
            Button("OK") {}
        } message: {
            Text("Allow photo access in Settings to suggest photos taken during this dive.")
        }
        .alert("No Matching Photos", isPresented: $showNoMatches) {
            Button("OK") {}
        } message: {
            Text("No library photos were taken during this dive.")
        }
    }

    private func save(assetIdentifier: String?, thumbnail: UIImage?) {
        let thumbnailFileName = thumbnail.flatMap { PhotoStore.saveThumbnail($0) }
        modelContext.insert(PhotoRecord(assetIdentifier: assetIdentifier, thumbnailFileName: thumbnailFileName, session: session))
        try? modelContext.save()
    }

    private func remove(_ photo: PhotoRecord) {
        PhotoStore.delete(photo.thumbnailFileName)
        modelContext.delete(photo)
        try? modelContext.save()
    }

    private func suggest() async {
        guard await PhotoMatcher.requestReadAccess() else { showPermissionAlert = true; return }
        let existing = Set(session.photos.compactMap { $0.assetIdentifier })
        let window = PhotoMatcher.window(start: session.startTime, end: session.endTime ?? session.startTime)
        let assets = PhotoMatcher.imageAssets(in: window, excluding: existing)
        suggestions = assets
        showSuggestions = !assets.isEmpty
        showNoMatches = assets.isEmpty
    }

    private func importAssets(_ assets: [PHAsset]) async {
        for asset in assets {
            let thumbnail = await PhotoLibrary.thumbnail(for: asset)
            let thumbnailFileName = thumbnail.flatMap { PhotoStore.saveThumbnail($0) }
            modelContext.insert(PhotoRecord(assetIdentifier: asset.localIdentifier, thumbnailFileName: thumbnailFileName, session: session))
        }
        try? modelContext.save()
    }
}

/// A spot's gallery — the union of its directly-attached photos and its sessions' photos.
struct SpotPhotosSection: View {
    let spot: Spot
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        PhotoGallerySection(
            photos: (spot.photos + spot.sessions.flatMap { $0.photos }).sorted { $0.createdAt < $1.createdAt },
            onAdd: { imported in
                let thumbnailFileName = PhotoStore.saveThumbnail(imported.thumbnail)
                modelContext.insert(PhotoRecord(assetIdentifier: imported.assetIdentifier, thumbnailFileName: thumbnailFileName, spot: spot))
                try? modelContext.save()
            },
            onDelete: { photo in
                PhotoStore.delete(photo.thumbnailFileName)
                modelContext.delete(photo)
                try? modelContext.save()
            }
        ) {
            EmptyView()
        }
    }
}

/// A square thumbnail: the cached thumbnail when present, else loaded from the
/// Photos library, else a placeholder (asset removed / access denied).
struct PhotoThumbnail: View {
    let photo: PhotoRecord
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.secondary.opacity(0.2)
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 80, height: 80)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: photo.id) { await load() }
    }

    private func load() async {
        if let name = photo.thumbnailFileName, let cached = await PhotoStore.thumbnailPrepared(for: name) {
            image = cached
            return
        }
        // Cache miss: fall back to a library thumbnail (e.g. cache was purged).
        guard let id = photo.assetIdentifier, await PhotoLibrary.requestAccess(),
              let asset = PhotoLibrary.asset(for: id) else { return }
        image = await PhotoLibrary.thumbnail(for: asset)
    }
}

/// Full-screen photo: loads the original from the Photos library on demand, with a
/// cached-thumbnail fallback and an "unavailable" state when the asset is gone.
struct FullScreenPhotoView: View {
    let photo: PhotoRecord
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var loading = true

    var body: some View {
        NavigationStack {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else if loading {
                    ProgressView().tint(.white)
                } else {
                    ContentUnavailableView(
                        "Photo Unavailable",
                        systemImage: "photo",
                        description: Text("This photo is no longer in your Photos library.")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) { onDelete(); dismiss() } label: {
                        Image(systemName: "trash")
                    }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        defer { loading = false }
        if let id = photo.assetIdentifier, await PhotoLibrary.requestAccess(),
           let full = await PhotoLibrary.fullImage(forIdentifier: id) {
            image = full
            return
        }
        // No original (deleted / no access): show the cached thumbnail if we have one.
        if let name = photo.thumbnailFileName {
            image = await PhotoStore.thumbnailPrepared(for: name)
        }
    }
}

/// Camera capture (SwiftUI has no native camera) — wraps `UIImagePickerController`.
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
