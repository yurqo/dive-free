import SwiftUI

/// Brief startup guidance shown when Apple Watch Ultra reports that Dive Free
/// isn't selected for submerged Auto-Launch.
struct AutoLaunchReminderView: View {
    @Binding var reminderEnabled: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "water.waves")
                        .font(.title2)
                        .foregroundStyle(.teal)
                    Text("Start Dive Free automatically")
                        .font(.headline)
                    Text("On Apple Watch Ultra, open Settings → General → Auto-Launch → When Submerged → Auto-Launch App, then choose Dive Free.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Remind me about Auto-Launch", isOn: $reminderEnabled)
                        .font(.caption)
                }
                .padding()
            }
            .navigationTitle("Auto-Launch")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
