import SwiftUI
import SwiftData
import Domain
import Persistence

/// The session's existing map and media, above the detail rows. The full map,
/// photo picker and gallery below remain available for reviewing/editing media.
struct SessionMediaHeader: View {
    let session: SessionRecord
    let domain: DiveSession
    let openMap: () -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.modelContext) private var modelContext
    @Environment(PhotoPagerPresenter.self) private var pager
    @State private var loadedPhotos: Set<UUID> = []

    private var photos: [PhotoRecord] {
        (session.photos ?? []).sorted {
            $0.createdAt == $1.createdAt
                ? $0.id.uuidString < $1.id.uuidString
                : $0.createdAt < $1.createdAt
        }
    }
    private var hasMap: Bool { !domain.track.isEmpty || domain.location != nil }
    private var title: String? {
        let trimmed = session.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.flatMap { $0.isEmpty ? nil : $0 }
    }
    private var gridHeight: CGFloat { sizeClass == .regular ? 285 : 225 }

    var body: some View {
        if hasMap || !photos.isEmpty || title != nil {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    if hasMap || !photos.isEmpty {
                        GeometryReader { geometry in
                            let photoWidth = hasMap ? (geometry.size.width - 4) * 5 / 9 : geometry.size.width
                            HStack(spacing: 4) {
                                if hasMap {
                                    mapTile
                                        .frame(width: photos.isEmpty ? geometry.size.width : (geometry.size.width - 4) * 4 / 9,
                                               height: gridHeight)
                                }
                                if !photos.isEmpty {
                                    photoGrid(width: photoWidth)
                                }
                            }
                        }
                        .frame(height: gridHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier(loadedPhotos.isSuperset(of: photos.prefix(4).map(\.id))
                                                 ? "session.media.header.ready" : "session.media.header")
                    }
                    if let title {
                        Text(title)
                            .font(.title2.bold())
                            .padding(.horizontal, 8)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("session.header.title")
                    }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
    }

    private var mapTile: some View {
        Button(action: openMap) {
            Group {
                if !domain.track.isEmpty {
                    SessionTrackMapView(session: domain, interactive: false)
                } else if let location = domain.location {
                    SessionMapView(location: location, interactive: false)
                }
            }
            .allowsHitTesting(false)
            .overlay(alignment: .topTrailing) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.callout)
                    .padding(8)
                    .background(.regularMaterial, in: Circle())
                    .padding(10)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Map")
        .accessibilityIdentifier("session.header.map")
    }

    @ViewBuilder
    private func photoGrid(width: CGFloat) -> some View {
        let visible = Array(photos.prefix(4))
        let cellWidth = visible.count == 1 || visible.count == 2 ? width : (width - 4) / 2
        let cellHeight = visible.count == 1 ? gridHeight : (gridHeight - 4) / 2
        VStack(spacing: 4) {
            if visible.count <= 2 {
                ForEach(visible) { photo in
                    photoTile(photo, width: cellWidth, height: cellHeight)
                }
            } else {
                HStack(spacing: 4) {
                    photoTile(visible[0], width: cellWidth, height: cellHeight)
                    photoTile(visible[1], width: cellWidth, height: cellHeight)
                }
                HStack(spacing: 4) {
                    photoTile(visible[2], width: visible.count == 3 ? width : cellWidth, height: cellHeight)
                    if visible.count == 4 {
                        photoTile(visible[3], width: cellWidth, height: cellHeight, additionalCount: photos.count - 4)
                    }
                }
            }
        }
        .frame(width: width, height: gridHeight)
    }

    private func photoTile(_ photo: PhotoRecord, width: CGFloat, height: CGFloat, additionalCount: Int = 0) -> some View {
        Button {
            // Use the stable root presenter, including every photo in the pager.
            pager.open(photos, initialID: photo.id) { deleted in
                PhotoStore.delete(deleted.thumbnailFileName)
                modelContext.delete(deleted)
                try? modelContext.save()
            }
        } label: {
            PhotoThumbnailImage(photo: photo, onLoad: { loadedPhotos.insert(photo.id) })
                .frame(width: width, height: height)
                .clipped()
                .overlay {
                    if additionalCount > 0 {
                        Text("+\(additionalCount)")
                            .font(.title2.bold())
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.black.opacity(0.35))
                    }
                }
                // Clipping pixels does not constrain SwiftUI hit testing. A
                // portrait image must not steal taps from the row above it.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(photo.isVideo ? Text("Video") : Text("Photo"))
        .accessibilityValue(loadedPhotos.contains(photo.id) ? Text("Ready") : Text("Loading…"))
        .accessibilityIdentifier("session.header.photo.\(photo.id)")
    }
}
