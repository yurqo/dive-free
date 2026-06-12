import SwiftUI

/// On-watch settings. Currently just the Digital Crown scroll speed for the
/// in-session action carousel, persisted via `@AppStorage` and read by
/// `SessionRootView`.
struct WatchSettingsView: View {
    @AppStorage("crownStepsPerItem") private var crownStepsPerItem = 3
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Higher detents-per-item = more rotation per item = slower,
                    // finer scrolling.
                    Picker("Scroll speed", selection: $crownStepsPerItem) {
                        Text("Fast").tag(1)
                        Text("Medium").tag(2)
                        Text("Slow").tag(3)
                        Text("Slowest").tag(4)
                    }
                } header: {
                    Text("Crown")
                } footer: {
                    Text("How far you turn the Digital Crown to move one item in the action carousel.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    WatchSettingsView()
}
