import SwiftUI
import SwiftData
import PhotosUI
import Photos
import AVKit
import UIKit
import UniformTypeIdentifiers
import Domain
import Persistence

/// A media item as handed to the owner to persist: a library reference (when one
/// was obtained) plus a thumbnail to cache for offline display (#141). Originals
/// are not copied — they stay in the Photos library. `isVideo` drives playback and
/// the play badge (#139).
struct ImportedPhoto {
    let assetIdentifier: String?
    let thumbnail: UIImage?
    var isVideo: Bool = false
}

/// A reusable "Photos" section: a thumbnail strip + add-from-library / take-photo
/// (plus any `extraActions` the owner adds), with full-screen view and delete. The
/// owner supplies the photos and the add/delete side effects.
struct PhotoGallerySection<Extra: View>: View {
    let photos: [PhotoRecord]
    let onAdd: ([ImportedPhoto]) -> Void
    let onDelete: (PhotoRecord) -> Void
    @ViewBuilder var extraActions: Extra

    @State private var libraryItems: [PhotosPickerItem] = []
    @State private var showCamera = false
    /// Identify the tapped photo by its stable id (not the SwiftData object) so a
    /// model refresh during the cover's first presentation can't dismiss it.
    @State private var presented: PresentedPhoto?

    private struct PresentedPhoto: Identifiable { let id: PhotoRecord.ID }

    var body: some View {
        Section("Photos") {
            if !photos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(photos) { photo in
                            Button { presented = PresentedPhoto(id: photo.id) } label: {
                                PhotoThumbnail(photo: photo)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
            // .shared() makes each picked item's `itemIdentifier` a library asset id
            // we can reference later, instead of an opaque copy. Multi-select +
            // the picker's own Add button = "multi-select + confirm" (#142); images
            // and videos (#139).
            PhotosPicker(selection: $libraryItems, matching: .any(of: [.images, .videos]), photoLibrary: .shared()) {
                Label("Add from Library", systemImage: "photo.on.rectangle")
            }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { showCamera = true } label: { Label("Take Photo or Video", systemImage: "camera") }
            }
            extraActions
        }
        .onChange(of: libraryItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                var imported: [ImportedPhoto] = []
                for item in items { imported.append(await importedPhoto(from: item)) }
                let valid = imported.filter { $0.assetIdentifier != nil || $0.thumbnail != nil }
                if !valid.isEmpty { onAdd(valid) }
                libraryItems = []
            }
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker { media in Task { await addCaptured(media) } }
                .ignoresSafeArea()
        }
        .fullScreenCover(item: $presented) { item in
            PhotoPagerView(photos: photos, initialID: item.id, onDelete: onDelete)
        }
    }

    /// Builds an `ImportedPhoto` from a picked item. When Photos access is granted,
    /// the asset's `mediaType` is authoritative (so a Live Photo isn't mistaken for
    /// a video) and yields the thumbnail (poster frame for a video); otherwise we
    /// fall back to the item's content types and its loaded image data.
    private func importedPhoto(from item: PhotosPickerItem) async -> ImportedPhoto {
        let identifier = item.itemIdentifier
        let asset = identifier.flatMap { PhotoLibrary.asset(for: $0) }
        let isVideo = asset.map { $0.mediaType == .video }
            ?? item.supportedContentTypes.contains { $0.conforms(to: .movie) }
        var thumbnail: UIImage?
        if let asset {
            thumbnail = await PhotoLibrary.thumbnail(for: asset)
        } else if !isVideo, let data = try? await item.loadTransferable(type: Data.self) {
            thumbnail = UIImage(data: data)
        }
        return ImportedPhoto(assetIdentifier: identifier, thumbnail: thumbnail, isVideo: isVideo)
    }

    /// Saves a camera capture to Photos and hands it to the owner.
    private func addCaptured(_ media: CapturedMedia) async {
        switch media {
        case .image(let image):
            onAdd([ImportedPhoto(assetIdentifier: await PhotoLibrary.save(image), thumbnail: image)])
        case .video(let url):
            let id = await PhotoLibrary.saveVideo(url)
            try? FileManager.default.removeItem(at: url)  // clean up the temp copy
            var poster: UIImage?
            if let id, let asset = PhotoLibrary.asset(for: id) { poster = await PhotoLibrary.thumbnail(for: asset) }
            onAdd([ImportedPhoto(assetIdentifier: id, thumbnail: poster, isVideo: true)])
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
            onAdd: { saveAll($0) },
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

    /// Persists imported photos (one store-save) and best-effort mirrors their
    /// library assets into the DiveFree / per-session Photos albums (#145).
    private func saveAll(_ imported: [ImportedPhoto]) {
        for photo in imported {
            let thumbnailFileName = photo.thumbnail.flatMap { PhotoStore.saveThumbnail($0) }
            modelContext.insert(PhotoRecord(assetIdentifier: photo.assetIdentifier, thumbnailFileName: thumbnailFileName, isVideo: photo.isVideo, session: session))
        }
        try? modelContext.save()
        mirrorSessionMedia(imported.compactMap(\.assetIdentifier), session: session, in: modelContext)
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
        let assets = PhotoMatcher.mediaAssets(in: window, excluding: existing)
        suggestions = assets
        showSuggestions = !assets.isEmpty
        showNoMatches = assets.isEmpty
    }

    private func importAssets(_ assets: [PHAsset]) async {
        var imported: [ImportedPhoto] = []
        for asset in assets {
            imported.append(ImportedPhoto(
                assetIdentifier: asset.localIdentifier,
                thumbnail: await PhotoLibrary.thumbnail(for: asset),
                isVideo: asset.mediaType == .video
            ))
        }
        saveAll(imported)
    }
}

extension SessionRecord {
    /// Name for this session's Photos album (#145): its title, else its date.
    var photoAlbumName: String {
        if let title, !title.isEmpty { return title }
        // Include the time so two untitled same-day dives don't collide on one album.
        return startTime.formatted(.dateTime.year().month(.abbreviated).day().hour().minute())
    }
}

/// Mirrors a session's just-imported media into Dive Free ▸ Spots ▸ <spot> ▸
/// <session> (and ▸ All), then persists the created folder/album ids back on the
/// session/spot so they're reused and renamed later. Reads model values on the
/// main actor, runs PhotoKit off it, writes the ids back on the main actor.
@MainActor
func mirrorSessionMedia(_ identifiers: [String], session: SessionRecord, in context: ModelContext) {
    guard !identifiers.isEmpty else { return }
    let spot = session.spot
    let spotName = spot?.name
    let spotFolderID = spot?.photosFolderIdentifier
    let sessionName = session.photoAlbumName
    let sessionAlbumID = session.photosAlbumIdentifier
    Task {
        let placement = await PhotoAlbum.mirror(
            assetIdentifiers: identifiers,
            spotName: spotName, spotFolderID: spotFolderID,
            sessionName: sessionName, sessionAlbumID: sessionAlbumID
        )
        session.photosAlbumIdentifier = placement.sessionAlbumID
        spot?.photosFolderIdentifier = placement.spotFolderID
        try? context.save()
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
                for photo in imported {
                    let thumbnailFileName = photo.thumbnail.flatMap { PhotoStore.saveThumbnail($0) }
                    modelContext.insert(PhotoRecord(assetIdentifier: photo.assetIdentifier, thumbnailFileName: thumbnailFileName, isVideo: photo.isVideo, spot: spot))
                }
                try? modelContext.save()
                // Spot-direct photos (no session) go in Dive Free ▸ All only (#145).
                let identifiers = imported.compactMap(\.assetIdentifier)
                Task { _ = await PhotoAlbum.mirror(assetIdentifiers: identifiers, spotName: nil, spotFolderID: nil, sessionName: nil, sessionAlbumID: nil) }
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
        .overlay {
            if photo.isVideo {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
            }
        }
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

/// Full-screen, swipeable gallery across a set of photos (#144). Each page loads
/// the original on demand and overlays the linked marker's info when present.
struct PhotoPagerView: View {
    let photos: [PhotoRecord]
    @State private var selection: PhotoRecord.ID
    let onDelete: (PhotoRecord) -> Void
    @Environment(\.dismiss) private var dismiss

    init(photos: [PhotoRecord], initialID: PhotoRecord.ID, onDelete: @escaping (PhotoRecord) -> Void) {
        self.photos = photos
        self._selection = State(initialValue: initialID)
        self.onDelete = onDelete
    }

    private var current: PhotoRecord? { photos.first { $0.id == selection } }

    var body: some View {
        NavigationStack {
            TabView(selection: $selection) {
                ForEach(photos) { photo in
                    PhotoPage(photo: photo, isActive: photo.id == selection).tag(photo.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: photos.count > 1 ? .automatic : .never))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        if let current { onDelete(current) }
                        dismiss()
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
    }
}

/// One page of `PhotoPagerView`: the original (cached-thumbnail / placeholder
/// fallback) plus a linked-marker banner when the photo belongs to a marker.
private struct PhotoPage: View {
    let photo: PhotoRecord
    let isActive: Bool
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var loading = true

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let marker = photo.marker {
                markerBanner(marker)
            }
        }
        .task { await load() }
        // Pause video audio when this page is swiped away (TabView keeps neighbors alive).
        .onChange(of: isActive) { _, active in
            if !active { player?.pause() }
        }
    }

    @ViewBuilder private var content: some View {
        if photo.isVideo, let player {
            VideoPlayer(player: player)
        } else if !photo.isVideo, let image {
            Image(uiImage: image).resizable().scaledToFit()
        } else if loading {
            ProgressView().tint(.white)
        } else {
            ContentUnavailableView(
                "Media Unavailable",
                systemImage: photo.isVideo ? "play.slash" : "photo",
                description: Text("This item is no longer in your Photos library.")
            )
        }
    }

    private func markerBanner(_ marker: MarkerRecord) -> some View {
        let kind = marker.toDomain().kind
        return HStack(spacing: 10) {
            Text(kind.emoji).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.label).font(.subheadline.weight(.semibold))
                if let text = marker.text, !text.isEmpty {
                    Text(text).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding()
    }

    private func load() async {
        defer { loading = false }
        if photo.isVideo {
            if let id = photo.assetIdentifier, await PhotoLibrary.requestAccess(),
               let item = await PhotoLibrary.playerItem(forIdentifier: id) {
                player = AVPlayer(playerItem: item)
            }
            return
        }
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

/// A photo or video captured by the camera (#139).
enum CapturedMedia {
    case image(UIImage)
    case video(URL)
}

/// Camera capture (SwiftUI has no native camera) — wraps `UIImagePickerController`,
/// offering both photo and video capture.
struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (CapturedMedia) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let url = info[.mediaURL] as? URL {
                // Copy out of the picker's tmp dir synchronously — it can be
                // reclaimed before the async save reads it (then the capture is lost).
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(url.pathExtension)
                try? FileManager.default.copyItem(at: url, to: dest)
                parent.onCapture(.video(dest))
            } else if let image = info[.originalImage] as? UIImage {
                parent.onCapture(.image(image))
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
