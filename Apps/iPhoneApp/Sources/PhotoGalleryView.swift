import SwiftUI
import PhotosUI
import Photos
import UIKit
import Persistence

/// A reusable "Photos" section: a thumbnail strip + add-from-library / take-photo
/// (plus any `extraActions` the owner adds), with full-screen view and delete. The
/// owner supplies the photos and the add/delete side effects.
struct PhotoGallerySection<Extra: View>: View {
    let photos: [PhotoRecord]
    let onAdd: (UIImage) -> Void
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
                            PhotoThumbnail(fileName: photo.fileName)
                                .onTapGesture { fullScreen = photo }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
            PhotosPicker(selection: $libraryItem, matching: .images) {
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
                    onAdd(image)
                }
                libraryItem = nil
            }
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker { onAdd($0) }.ignoresSafeArea()
        }
        .fullScreenCover(item: $fullScreen) { photo in
            FullScreenPhotoView(fileName: photo.fileName) { onDelete(photo) }
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
            onAdd: { save($0) },
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

    private func save(_ image: UIImage, assetIdentifier: String? = nil) {
        guard let fileName = PhotoStore.save(image) else { return }
        modelContext.insert(PhotoRecord(fileName: fileName, assetIdentifier: assetIdentifier, session: session))
        try? modelContext.save()
    }

    private func remove(_ photo: PhotoRecord) {
        PhotoStore.delete(photo.fileName)
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
            guard let image = await PhotoMatcher.fullImage(for: asset) else { continue }
            save(image, assetIdentifier: asset.localIdentifier)
        }
    }
}

/// A spot's gallery — the union of its directly-attached photos and its sessions' photos.
struct SpotPhotosSection: View {
    let spot: Spot
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        PhotoGallerySection(
            photos: (spot.photos + spot.sessions.flatMap { $0.photos }).sorted { $0.createdAt < $1.createdAt },
            onAdd: { image in
                guard let fileName = PhotoStore.save(image) else { return }
                modelContext.insert(PhotoRecord(fileName: fileName, spot: spot))
                try? modelContext.save()
            },
            onDelete: { photo in
                PhotoStore.delete(photo.fileName)
                modelContext.delete(photo)
                try? modelContext.save()
            }
        ) {
            EmptyView()
        }
    }
}

/// A square thumbnail loaded from `PhotoStore`.
struct PhotoThumbnail: View {
    let fileName: String

    var body: some View {
        Group {
            if let image = PhotoStore.thumbnail(for: fileName) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.secondary.opacity(0.2)
            }
        }
        .frame(width: 80, height: 80)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Full-screen photo with Done + delete.
struct FullScreenPhotoView: View {
    let fileName: String
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let image = PhotoStore.image(for: fileName) {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    ContentUnavailableView("Image Unavailable", systemImage: "photo")
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
