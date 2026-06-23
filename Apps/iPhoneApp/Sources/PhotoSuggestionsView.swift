import SwiftUI
import Photos
import UIKit

/// Review sheet for timestamp-matched camera-roll photos — the user picks which to
/// attach (nothing is imported silently).
struct PhotoSuggestionsView: View {
    let assets: [PHAsset]
    let onImport: ([PHAsset]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 4)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(assets, id: \.localIdentifier) { asset in
                        SuggestionCell(asset: asset, isSelected: selected.contains(asset.localIdentifier))
                            .onTapGesture { toggle(asset.localIdentifier) }
                    }
                }
                .padding(4)
            }
            .navigationTitle("Photos from This Dive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(allSelected ? "Deselect All" : "Select All") { toggleAll() }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Add \(selected.count)") {
                        onImport(assets.filter { selected.contains($0.localIdentifier) })
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
    }

    private var allSelected: Bool { !assets.isEmpty && selected.count == assets.count }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func toggleAll() {
        selected = allSelected ? [] : Set(assets.map(\.localIdentifier))
    }
}

private struct SuggestionCell: View {
    let asset: PHAsset
    let isSelected: Bool
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Color.secondary.opacity(0.2)
                }
            }
            .frame(width: 100, height: 100)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, isSelected ? Color.accentColor : .black.opacity(0.4))
                .padding(5)
        }
        .task(id: asset.localIdentifier) {
            PhotoMatcher.requestThumbnail(for: asset, targetSize: CGSize(width: 200, height: 200)) { image = $0 }
        }
    }
}
