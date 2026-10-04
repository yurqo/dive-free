import SwiftUI
import SwiftData

/// Top-level tabs: Dives, Trips, Spots, and Passport. The sidebar-adaptable
/// style keeps a bottom tab bar on iPhone (compact) and shows a sidebar on iPad
/// (regular width), so the destinations feel native on both (#170).
struct RootTabView: View {
    @State private var selectedTab = "tab.dives"
    @Environment(\.modelContext) private var modelContext
    @Environment(PhotoPagerPresenter.self) private var pager
    @Environment(PhotoSuggestionPresenter.self) private var suggestions

    var body: some View {
        @Bindable var pager = pager
        @Bindable var suggestions = suggestions
        TabView(selection: $selectedTab) {
            // Stable, locale-independent a11y identifiers per tab. Used by the
            // screenshot UI test to select tabs regardless of localized titles
            // and regardless of layout (bottom tab bar on iPhone vs. sidebar on
            // iPad, where SwiftUI renders rows as cells/buttons rather than
            // tab-bar buttons).
            Tab("Dives", systemImage: "water.waves", value: "tab.dives") {
                SessionListView()
            }
            .accessibilityIdentifier("tab.dives")
            Tab("Trips", systemImage: "suitcase", value: "tab.trips") {
                TripsView()
            }
            .accessibilityIdentifier("tab.trips")
            Tab("Spots", systemImage: "mappin.and.ellipse", value: "tab.spots") {
                SpotsListView()
            }
            .accessibilityIdentifier("tab.spots")
            Tab("Passport", systemImage: "rosette", value: "tab.passport") {
                StatsView()
            }
            .accessibilityIdentifier("tab.passport")
        }
        .tabViewStyle(.sidebarAdaptable)
        #if DEBUG
        .task {
            let arguments = ProcessInfo.processInfo.arguments
            guard arguments.contains("--screenshot-demo"),
                  let flag = arguments.firstIndex(of: "--screenshot-screen"),
                  arguments.indices.contains(flag + 1) else { return }
            let tabs = ["03-trips": "tab.trips", "04-spots": "tab.spots", "05-passport": "tab.passport"]
            if let tab = tabs[arguments[flag + 1]] { selectedTab = tab }
        }
        #endif
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
