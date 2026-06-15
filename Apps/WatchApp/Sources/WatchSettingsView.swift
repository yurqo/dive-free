import SwiftUI

/// Settings page of the watch home pager: the Digital Crown scroll speed for the
/// in-session action carousel, persisted via `@AppStorage` and read by
/// `SessionRootView`.
struct WatchSettingsView: View {
    // Detents-per-item: higher = more rotation per item = slower, finer scroll.
    // The scale is deliberately slow — even "Fast" (3) is the old "Slow"; the
    // old values felt far too fast, especially underwater.
    @AppStorage("crownStepsPerItem") private var crownStepsPerItem = 6

    var body: some View {
        NavigationStack {
            Form {
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

#Preview {
    WatchSettingsView()
}
