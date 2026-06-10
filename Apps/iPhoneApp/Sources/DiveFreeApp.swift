import SwiftUI
import SwiftData
import Persistence
import Sync

@main
struct DiveFreeApp: App {
    @State private var sync = SyncManager()

    var body: some Scene {
        WindowGroup {
            SessionListView()
                .onAppear { sync.activate() }
        }
        .modelContainer(for: SessionRecord.self)
    }
}
