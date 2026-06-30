import SwiftUI

/// Top-level tabs: the dive history and the dive spots. The sidebar-adaptable
/// style keeps a bottom tab bar on iPhone (compact) and shows a sidebar on iPad
/// (regular width), so the same two destinations feel native on both (#170).
struct RootTabView: View {
    var body: some View {
        TabView {
            Tab("Dives", systemImage: "water.waves") {
                SessionListView()
            }
            Tab("Spots", systemImage: "mappin.and.ellipse") {
                SpotsListView()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}
