import SwiftUI

/// Top-level tabs: the dive history and the dive spots.
struct RootTabView: View {
    var body: some View {
        TabView {
            SessionListView()
                .tabItem { Label("Dives", systemImage: "water.waves") }
            SpotsListView()
                .tabItem { Label("Spots", systemImage: "mappin.and.ellipse") }
        }
    }
}
