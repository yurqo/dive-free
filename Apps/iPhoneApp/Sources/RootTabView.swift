import SwiftUI

/// Top-level tabs: Dives, Trips, Spots, and Passport. The sidebar-adaptable
/// style keeps a bottom tab bar on iPhone (compact) and shows a sidebar on iPad
/// (regular width), so the destinations feel native on both (#170).
struct RootTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PhotoPagerPresenter.self) private var pager
    @Environment(PhotoSuggestionPresenter.self) private var suggestions

    var body: some View {
        @Bindable var pager = pager
        @Bindable var suggestions = suggestions
        TabView {
            Tab("Dives", systemImage: "water.waves") {
                SessionListView()
            }
            Tab("Trips", systemImage: "suitcase") {
                TripsView()
            }
            Tab("Spots", systemImage: "mappin.and.ellipse") {
                SpotsListView()
            }
            Tab("Passport", systemImage: "rosette") {
                StatsView()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        // Repair photos imported before the cross-device fields existed so they
        // resolve on other devices (#169). Idempotent; no-op once filled in.
        .task { await PhotoBackfill.run(in: modelContext) }
        // The full-screen photo pager is presented here (stable across list
        // re-renders), not from inside a List row that gets torn down (#118 follow-up).
        .fullScreenCover(item: $pager.request) { request in
            PhotoPagerView(photos: request.photos, initialID: request.initialID, onDelete: request.onDelete)
        }
        // Photo-suggest selection sheet, also presented top-level so a list
        // re-render on first open can't dismiss it (#126 follow-up).
        .sheet(item: $suggestions.request) { request in
            PhotoSuggestionsView(assets: request.assets) { picked in
                request.onConfirm(picked)
                suggestions.request = nil
            }
        }
    }
}
