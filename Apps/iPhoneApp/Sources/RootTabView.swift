import SwiftUI

/// Top-level tabs: the dive history and the dive spots. The sidebar-adaptable
/// style keeps a bottom tab bar on iPhone (compact) and shows a sidebar on iPad
/// (regular width), so the same two destinations feel native on both (#170).
struct RootTabView: View {
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        TabView {
            Tab("Dives", systemImage: "water.waves") {
                SessionListView()
            }
            Tab("Spots", systemImage: "mappin.and.ellipse") {
                SpotsListView()
            }
            Tab("Passport", systemImage: "rosette") {
                StatsView()
            }
            Tab("Trips", systemImage: "suitcase") {
                TripsView()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        // Repair photos imported before the cross-device fields existed so they
        // resolve on other devices (#169). Idempotent; no-op once filled in.
        .task { await PhotoBackfill.run(in: modelContext) }
    }
}
