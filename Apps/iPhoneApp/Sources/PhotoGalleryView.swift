import SwiftUI
import PhotosUI
import UIKit
import Persistence

/// A reusable "Photos" section: a thumbnail strip + add-from-library / take-photo,
/// with full-screen view and delete. The owner supplies the photos and the
/// add/delete side effects (so it serves both sessions and spots).
struct PhotoGallerySection: View {
    let photos: [PhotoRecord]
    let onAdd: (UIImage) -> Void
    let onDelete: (PhotoRecord) -> Void

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

/// Photos attached to a session.
struct SessionPhotosSection: View {
    let session: SessionRecord
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        PhotoGallerySection(
            photos: session.photos.sorted { $0.createdAt < $1.createdAt },
            onAdd: { image in
                guard let fileName = PhotoStore.save(image) else { return }
                modelContext.insert(PhotoRecord(fileName: fileName, session: session))
                try? modelContext.save()
            },
            onDelete: { photo in
                PhotoStore.delete(photo.fileName)
                modelContext.delete(photo)
                try? modelContext.save()
            }
        )
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
        )
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
