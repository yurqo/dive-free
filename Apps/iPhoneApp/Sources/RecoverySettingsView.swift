import SwiftUI
import Domain
import Sync

/// Surface-recovery settings: whether the watch's between-dives recovery hint runs,
/// and the rest-to-dive multiplier behind the recommended interval.
///
/// Recovery is its own Settings row (a diver tunes it far more often than the
/// detection tiers), but **not** its own preference store: this screen reads and
/// writes the very same `DiveDetectionSettings` `@AppStorage` blob as
/// `DiveDetectionSettingsView` — see that file for the storage shape — and pushes the
/// same `DiveDetectionConfig` to the watch on change. Splitting the UI must not split
/// the data, so a diver's existing choices carry over untouched.
struct RecoverySettingsView: View {
    @Environment(\.syncManager) private var sync

    @AppStorage(DiveDetectionSettings.storageKey) private var settings = DiveDetectionSettings.default

    var body: some View {
        Form {
            Section {
                Toggle("Recovery hint", isOn: $settings.recoveryEnabled)
                Picker("Recommended interval", selection: $settings.recoveryMultiplier) {
                    // Tags must match `DiveDetectionSettings.multiplierOptions`, which
                    // the decoded value is snapped to — so the selection is never blank.
                    ForEach(DiveDetectionSettings.multiplierOptions, id: \.self) { multiplier in
                        Text(multiplier.formatted(.number.precision(.fractionLength(0...1))) + "×").tag(multiplier)
                    }
                }
                .disabled(!settings.recoveryEnabled)
            } footer: {
                Text("Between dives, the watch's surface timer turns green — with a buzz — once you've rested the recommended interval: this multiple of your last dive's time, and at least 1 minute. The green clears again shortly after, so it always means you're rested right now. This is a common rule of thumb, not medical or safety advice — always dive with a buddy.")
            }
        }
        .navigationTitle("Recovery")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: settings) { syncDetection() }
    }

    /// Push the (just-written) detection config to the watch — the same blob and the
    /// same call the Dive detection screen makes.
    private func syncDetection() {
        sync?.sendDetectionConfig(settings.config)
    }
}

#Preview {
    NavigationStack {
        RecoverySettingsView()
    }
}
