import SwiftUI
import Domain
import Sync

/// Editable, phone-local model behind the Dive Detection settings screen: three
/// tier slots (each individually enable-able) plus the surface-exit dwell. Stored
/// as ONE `@AppStorage` JSON blob (via `RawRepresentable`) so it ships over sync in
/// one payload, and converted to a `DiveDetectionConfig` (enabled tiers only,
/// sanitized) for `sendDetectionConfig`.
///
/// The type is `RawRepresentable(String)` but deliberately **not** `Codable`: a
/// type that is both recurses to death — the stdlib's Codable witness for a
/// `RawValue == String` type encodes `self.rawValue`, and `rawValue` here JSON-
/// encodes `self`, so encoding SIGSEGVs on the first edit (and decoding never round-
/// trips a bare string). `rawValue` / `init?(rawValue:)` serialise a private `Blob`
/// DTO instead, keeping the JSON shape without any Codable conformance on the outer
/// type. `Tier` stays `Codable` — it isn't `RawRepresentable`, so it can't recurse.
struct DiveDetectionSettings: Equatable, RawRepresentable {
    struct Tier: Codable, Equatable {
        var isEnabled: Bool
        var depthMeters: Double
        var seconds: Int
    }

    var tiers: [Tier]
    var dwellSeconds: Int
    /// Whether the watch's surface-recovery hint (colour + buzz) is on. Mirrors
    /// `DiveDetectionConfig.recoveryEnabled`.
    var recoveryEnabled: Bool
    /// Recommended surface interval = `recoveryMultiplier × the last dive's time`
    /// (at least 1 min). Mirrors `DiveDetectionConfig.recoveryMultiplier`.
    var recoveryMultiplier: Double

    /// Mirrors `DiveDetectionConfig.default`: a duck dive to 2 m (≥2 s), a normal
    /// 1.5 m dive (≥3 s), or a sustained shallow dive past 1 m (≥5 s); dive ends
    /// after 3 s shallow; recovery hint on at 3×.
    static let `default` = DiveDetectionSettings(
        tiers: [
            Tier(isEnabled: true, depthMeters: 2.0, seconds: 2),
            Tier(isEnabled: true, depthMeters: 1.5, seconds: 3),
            Tier(isEnabled: true, depthMeters: 1.0, seconds: 5),
        ],
        dwellSeconds: 3,
        recoveryEnabled: true,
        recoveryMultiplier: 3.0
    )

    init(tiers: [Tier], dwellSeconds: Int, recoveryEnabled: Bool = true, recoveryMultiplier: Double = 3.0) {
        self.tiers = tiers
        self.dwellSeconds = dwellSeconds
        self.recoveryEnabled = recoveryEnabled
        self.recoveryMultiplier = recoveryMultiplier
    }

    /// Compare by value. `RawRepresentable(String)` + `Equatable` otherwise resolves
    /// `==` to the stdlib's `rawValue`-based witness, and our `rawValue` is JSON whose
    /// key order isn't guaranteed — so two equal values can compare unequal. An
    /// explicit memberwise `==` (preferred over the protocol default) keeps
    /// `settings == .default` and `.onChange(of:)` reliable.
    static func == (lhs: DiveDetectionSettings, rhs: DiveDetectionSettings) -> Bool {
        lhs.tiers == rhs.tiers
            && lhs.dwellSeconds == rhs.dwellSeconds
            && lhs.recoveryEnabled == rhs.recoveryEnabled
            && lhs.recoveryMultiplier == rhs.recoveryMultiplier
    }

    // MARK: RawRepresentable (JSON string) for @AppStorage

    /// The `@AppStorage` key backing the blob — exposed so the launch-time push in
    /// `DiveFreeApp` reads the same store the settings screen writes.
    static let storageKey = "diveDetectionSettings"

    /// The private, plain-`Codable` DTO the blob actually serialises. Serialising a
    /// separate type (never `self`) is what breaks the `rawValue`↔︎`encode` recursion.
    private struct Blob: Codable {
        var tiers: [Tier]
        var dwellSeconds: Int
        // Added with surface recovery — optional so a blob persisted before this
        // feature (missing these keys) still decodes, falling back to defaults.
        var recoveryEnabled: Bool?
        var recoveryMultiplier: Double?
    }

    init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let blob = try? JSONDecoder().decode(Blob.self, from: data)
        else { return nil }
        self.tiers = blob.tiers
        self.dwellSeconds = blob.dwellSeconds
        self.recoveryEnabled = blob.recoveryEnabled ?? true
        // Snap to one of the Picker's tags so the bound selection is never blank:
        // Domain's continuous [1.5, 5.0] clamp (or a legacy/hand-edited blob) can
        // yield e.g. 2.75, which has no tag and renders an empty Picker.
        self.recoveryMultiplier = Self.snappedMultiplier(blob.recoveryMultiplier ?? 3.0)
    }

    /// The multiplier Picker's options; the bound value is snapped to one of these
    /// so a selection is always shown (see `init?(rawValue:)`).
    static let multiplierOptions: [Double] = [2.0, 2.5, 3.0]

    /// Snaps an arbitrary multiplier to the nearest Picker option, so the bound
    /// value is always exactly one of the tags.
    static func snappedMultiplier(_ value: Double) -> Double {
        multiplierOptions.min { abs($0 - value) < abs($1 - value) } ?? 3.0
    }

    var rawValue: String {
        let blob = Blob(
            tiers: tiers,
            dwellSeconds: dwellSeconds,
            recoveryEnabled: recoveryEnabled,
            recoveryMultiplier: recoveryMultiplier
        )
        let encoder = JSONEncoder()
        // Stable key order so the persisted blob (and any sync payload) is
        // byte-identical for equal values — no spurious @AppStorage rewrites.
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(blob),
              let string = String(data: data, encoding: .utf8) else { return "" }
        return string
    }

    /// Loads the persisted settings from `UserDefaults` (the same blob `@AppStorage`
    /// writes under `storageKey`), falling back to `.default` when absent or unparseable.
    static func load(from defaults: UserDefaults = .standard) -> DiveDetectionSettings {
        guard let raw = defaults.string(forKey: storageKey),
              let settings = DiveDetectionSettings(rawValue: raw) else { return .default }
        return settings
    }

    /// Number of currently-enabled tiers (at least one must stay on).
    var enabledCount: Int { tiers.filter(\.isEnabled).count }

    /// The synced detection config: enabled tiers only (falling back to the default
    /// tiers if somehow none survive), with the dwell — then `sanitized()` so the
    /// watch never receives out-of-range values.
    var config: DiveDetectionConfig {
        let thresholds = tiers.filter(\.isEnabled).map {
            DiveDetectionConfig.DiveThreshold(minimumDepthMeters: $0.depthMeters, minimumDuration: TimeInterval($0.seconds))
        }
        return DiveDetectionConfig(
            surfaceExitDwellSeconds: TimeInterval(dwellSeconds),
            thresholds: thresholds.isEmpty ? DiveDetectionConfig.default.thresholds : thresholds,
            recoveryEnabled: recoveryEnabled,
            recoveryMultiplier: recoveryMultiplier
        ).sanitized()
    }
}

/// Lets the diver tune the dive-detection tiers (depth + minimum time, OR-ed) and
/// the end-of-dive dwell on the iPhone. Persisted as one `@AppStorage` blob and
/// synced to the watch on every change; applies to the watch's next session.
struct DiveDetectionSettingsView: View {
    @Environment(\.syncManager) private var sync

    @AppStorage(DiveDetectionSettings.storageKey) private var settings = DiveDetectionSettings.default

    /// Depth options (m) offered per tier: 1.0–6.0 in 0.5 m steps. 6 m is the
    /// sensor's measurable ceiling; the floor matches the fixed surface threshold.
    private let depthOptions: [Double] = stride(from: 1.0, through: 6.0, by: 0.5).map { $0 }

    private var units: UnitPreference { .current }

    var body: some View {
        Form {
            ForEach(settings.tiers.indices, id: \.self) { index in
                tierSection(index)
            }

            Section {
                Picker("Dive ends after", selection: $settings.dwellSeconds) {
                    ForEach(1...10, id: \.self) { Text("\($0) s").tag($0) }
                }
            } footer: {
                Text("A dive always ends the moment you reach the surface (0 m). This is how long you can rest shallower than 1 m — without surfacing — before the dive is treated as ended.")
            }

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
            } header: {
                Text("Surface recovery")
            } footer: {
                Text("Between dives, the watch's surface timer turns green — with a buzz — once you've rested the recommended interval: this multiple of your last dive's time, and at least 1 minute. This is a common rule of thumb, not medical or safety advice — always dive with a buddy.")
            }

            Section {
                Button("Reset to defaults") { settings = .default }
                    .disabled(settings == .default)
            } footer: {
                Text("A dive counts when it meets ANY enabled rule — the deeper you go, the sooner it registers. Keep at least one rule on.")
            }
        }
        .navigationTitle("Dive detection")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: settings) { syncDetection() }
    }

    @ViewBuilder private func tierSection(_ index: Int) -> some View {
        // The only enabled tier can't be switched off — at least one rule must stay.
        let isOnlyEnabled = settings.tiers[index].isEnabled && settings.enabledCount == 1
        Section {
            Toggle("Rule \(index + 1)", isOn: $settings.tiers[index].isEnabled)
                .disabled(isOnlyEnabled)
            if settings.tiers[index].isEnabled {
                Picker("Depth", selection: $settings.tiers[index].depthMeters) {
                    ForEach(depthOptions, id: \.self) { meters in
                        // Exact label (no ceiling "+"): these are selectable thresholds,
                        // not measured readings, so "6 m" must not read as "beyond 6 m".
                        Text(DepthFormat.exact(meters, units: units)).tag(meters)
                    }
                }
                Picker("For at least", selection: $settings.tiers[index].seconds) {
                    ForEach(1...30, id: \.self) { Text("\($0) s").tag($0) }
                }
            }
        }
    }

    /// Push the (just-written) detection config to the watch — same pattern as the
    /// units sync.
    private func syncDetection() {
        sync?.sendDetectionConfig(settings.config)
    }
}

#Preview {
    NavigationStack {
        DiveDetectionSettingsView()
    }
}
