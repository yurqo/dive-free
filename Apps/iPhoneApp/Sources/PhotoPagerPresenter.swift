import SwiftUI
import Persistence

/// Presents the full-screen photo pager from a **stable** top-level view (attached
/// once in `RootTabView`), decoupled from the List rows that trigger it.
///
/// A `.fullScreenCover` attached inside a `List` section is torn down when the list
/// re-renders — e.g. a CloudKit import or a backfill `save()` landing right after
/// the first tap — which dismissed the viewer on the first open ("opens then
/// immediately closes"). Routing the presentation through this presenter, whose
/// cover lives on a view that never recycles, makes the first open stick.
@MainActor
@Observable
final class PhotoPagerPresenter {
    struct Request: Identifiable {
        let id = UUID()
        let photos: [PhotoRecord]
        let initialID: PhotoRecord.ID
        let onDelete: (PhotoRecord) -> Void
    }

    var request: Request?

    func open(_ photos: [PhotoRecord], initialID: PhotoRecord.ID, onDelete: @escaping (PhotoRecord) -> Void) {
        request = Request(photos: photos, initialID: initialID, onDelete: onDelete)
    }
}
