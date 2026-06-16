import SwiftUI
import Domain

/// Settings page of the watch home pager: the default marker and the Digital
/// Crown scroll speed for the in-session action carousel, persisted via
/// `@AppStorage` and read by `SessionRootView` / `SessionCoordinator`.
struct WatchSettingsView: View {
    @Environment(SessionCoordinator.self) private var session

    // Detents-per-item: higher = more rotation per item = slower, finer scroll.
    // The scale is deliberately slow — even "Fast" (3) is the old "Slow"; the
    // old values felt far too fast, especially underwater.
    @AppStorage("crownStepsPerItem") private var crownStepsPerItem = 6
    @AppStorage("defaultMarkerKindID") private var defaultMarkerKindID = EventKind.note.rawValue

    /// Built-in kinds, plus any custom kinds synced from the iPhone.
    private var markerKinds: [MarkerKind] { EventKind.builtInMarkerKinds + session.customKinds }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Default marker", selection: $defaultMarkerKindID) {
                        ForEach(markerKinds) { kind in
                            Text("\(kind.emoji) \(kind.label)").tag(kind.id)
                        }
                    }
                } header: {
                    Text("Markers")
                } footer: {
                    Text("Pre-selected in the action carousel, and what the Action button drops while you're underwater.")
                }

                Section {
                    Picker("Scroll speed", selection: $crownStepsPerItem) {
                        Text("Fast").tag(3)
                        Text("Medium").tag(4)
                        Text("Slow").tag(6)
                        Text("Slowest").tag(9)
                    }
                } header: {
                    Text("Crown")
                } footer: {
                    Text("How far you turn the Digital Crown to move one item in the action carousel. Slower is easier underwater.")
                }
            }
            .navigationTitle("Settings")
        }
    }
}
