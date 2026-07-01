import SwiftUI
import Photos

/// Presents the "Suggest from This Dive" selection sheet from a **stable**
/// top-level view (attached in `RootTabView`), not from inside the session
/// detail's `List` — a sheet attached to a List row is torn down when the list
/// re-renders (e.g. the first CloudKit import right after opening the detail),
/// which dismissed the sheet on the first open. Same fix as `PhotoPagerPresenter`.
@MainActor
@Observable
final class PhotoSuggestionPresenter {
    struct Request: Identifiable {
        let id = UUID()
        let assets: [PHAsset]
        let onConfirm: ([PHAsset]) -> Void
    }

    var request: Request?

    func present(_ assets: [PHAsset], onConfirm: @escaping ([PHAsset]) -> Void) {
        request = Request(assets: assets, onConfirm: onConfirm)
    }
}
