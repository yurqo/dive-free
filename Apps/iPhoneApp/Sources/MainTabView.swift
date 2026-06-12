import SwiftUI

/// Top-level navigation: three horizontally-swipeable pages — Stats, the dive
/// history, and Settings. Each page owns its own `NavigationStack` so pushes
/// (e.g. into a session's detail) stay within that page.
struct MainTabView: View {
    private enum Page: Hashable {
        case stats, dives, settings
    }

    @State private var page: Page = .dives

    var body: some View {
        TabView(selection: $page) {
            NavigationStack { StatsView() }
                .tag(Page.stats)

            NavigationStack { SessionListView() }
                .tag(Page.dives)

            NavigationStack { SettingsView() }
                .tag(Page.settings)
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
    }
}
