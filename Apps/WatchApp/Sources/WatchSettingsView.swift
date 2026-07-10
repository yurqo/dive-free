import SwiftUI
import WatchKit
import Domain
import Sensors

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
    @AppStorage(GPSPrecision.highPrecisionKey) private var highPrecisionGPS = false

    // Periodic underwater time cues (#178). Default off so existing users aren't
    // surprised by new sounds; 0 disables a tier.
    @AppStorage("timeCuesEnabled") private var timeCuesEnabled = false
    @AppStorage("timeCueMinorSeconds") private var timeCueMinorSeconds = 10
    @AppStorage("timeCueMajorSeconds") private var timeCueMajorSeconds = 60

    // Units — synced from the iPhone, but also adjustable here. Each dimension is
    // stored independently so the Custom pickers bind directly.
    @AppStorage(UnitPreference.Key.mode) private var unitModeRaw = UnitPreference.regionDefault.mode.rawValue
    @AppStorage(UnitPreference.Key.depth) private var depthRaw = UnitPreference.regionDefault.customDepth.rawValue
    @AppStorage(UnitPreference.Key.distance) private var distanceRaw = UnitPreference.regionDefault.customDistance.rawValue
    @AppStorage(UnitPreference.Key.temperature) private var temperatureRaw = UnitPreference.regionDefault.customTemperature.rawValue

    #if targetEnvironment(simulator)
    // Debug overrides to fake device capabilities in the Simulator (which has no
    // real sensors). Simulator builds only.
    @AppStorage(SimCapabilityOverride.depthSensorKey) private var simDepthSensor = true
    @AppStorage(SimCapabilityOverride.actionButtonKey) private var simActionButton = true
    #endif

    /// Transient confirmation for the "Re-send all" button: flips the label after a
    /// tap and reverts after a short window (also a double-tap debounce), so the
    /// button can be used again later in the same visit.
    @State private var resyncedAll = false

    // Retention: auto-clean synced sessions off the watch (they stay on the
    // iPhone / iCloud). Off by default; each cap of 0 is disabled.
    @AppStorage("retentionEnabled") private var retentionEnabled = false
    @AppStorage("retentionMaxDays") private var retentionMaxDays = 0
    @AppStorage("retentionMaxSessions") private var retentionMaxSessions = 0
    @AppStorage("retentionMaxMegabytes") private var retentionMaxMegabytes = 0
    /// On-watch storage total (count, bytes), refreshed when the view appears.
    @State private var storage: (count: Int, bytes: Int) = (0, 0)

    /// Built-in kinds, plus any custom kinds synced from the iPhone.
    private var markerKinds: [MarkerKind] { EventKind.builtInMarkerKinds + session.customKinds }

    private var storageSummary: String {
        let mb = Double(storage.bytes) / 1_048_576
        let size = mb < 1 ? "<1 MB" : String(format: "~%.0f MB", mb)
        return "\(storage.count) · \(size)"
    }

    /// Re-prune and refresh the total when a retention cap changes.
    private func applyRetention() {
        session.pruneForRetention()
        storage = session.storageTotals()
    }

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
                    NavigationLink {
                        ScrollSpeedView()
                    } label: {
                        HStack {
                            Text("Scroll speed")
                            Spacer()
                            Text(ScrollSpeedView.label(forSteps: crownStepsPerItem))
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Crown")
                } footer: {
                    Text("Turn the Crown to feel each speed before you pick. Slower is easier underwater.")
                }

                Section {
                    Toggle("High precision", isOn: $highPrecisionGPS)
                } header: {
                    Text("GPS")
                } footer: {
                    Text("More accurate dive-spot location and surface track. Drains the battery faster. Applies to your next session.")
                }

                Section {
                    Text(session.detectionSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Dive detection")
                } footer: {
                    Text("Set on iPhone. Applies to your next session.")
                }

                Section {
                    Toggle("Time cues", isOn: $timeCuesEnabled)
                    if timeCuesEnabled {
                        Picker("Minor", selection: $timeCueMinorSeconds) {
                            Text("Off").tag(0)
                            Text("5s").tag(5)
                            Text("10s").tag(10)
                            Text("15s").tag(15)
                            Text("20s").tag(20)
                            Text("30s").tag(30)
                        }
                        Picker("Major", selection: $timeCueMajorSeconds) {
                            Text("Off").tag(0)
                            Text("30s").tag(30)
                            Text("1min").tag(60)
                            Text("90s").tag(90)
                            Text("2min").tag(120)
                        }
                    }
                } header: {
                    Text("Time cues")
                } footer: {
                    Text("Plays a tone underwater at each interval — a distinct double tone at the major mark — so you can track dive time hands-free. Awareness only, not a dive timer.")
                }

                Section {
                    Picker("Units", selection: $unitModeRaw) {
                        Text("Metric").tag(UnitMode.metric.rawValue)
                        Text("Imperial").tag(UnitMode.imperial.rawValue)
                        Text("Custom").tag(UnitMode.custom.rawValue)
                    }
                    if unitModeRaw == UnitMode.custom.rawValue {
                        Picker("Depth", selection: $depthRaw) {
                            Text("Meters").tag(DepthUnit.meters.rawValue)
                            Text("Feet").tag(DepthUnit.feet.rawValue)
                        }
                        Picker("Distance", selection: $distanceRaw) {
                            Text("Metric").tag(DistanceUnit.metric.rawValue)
                            Text("Imperial").tag(DistanceUnit.imperial.rawValue)
                        }
                        Picker("Temperature", selection: $temperatureRaw) {
                            Text("Celsius").tag(TemperatureUnit.celsius.rawValue)
                            Text("Fahrenheit").tag(TemperatureUnit.fahrenheit.rawValue)
                        }
                    }
                } header: {
                    Text("Units")
                } footer: {
                    Text("Syncs from your iPhone. Change it here to override on the watch.")
                }

                Section {
                    Button {
                        session.resyncAll()
                        WKInterfaceDevice.current().play(.success)
                        resyncedAll = true
                        // Revert the confirmation after a short window so the button
                        // can be re-used later in the same visit; the `.disabled`
                        // below debounces double-taps until then.
                        Task {
                            try? await Task.sleep(for: .seconds(2.5))
                            resyncedAll = false
                        }
                    } label: {
                        Label(resyncedAll ? "Sent all to iPhone" : "Re-send all to iPhone",
                              systemImage: resyncedAll ? "checkmark.circle" : "arrow.triangle.2.circlepath")
                    }
                    .disabled(resyncedAll)
                } header: {
                    Text("Sync")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Re-send every session on this watch to your iPhone — use it if some dives didn't show up there.")
                        if session.pendingSyncCount > 0 {
                            Text("\(session.pendingSyncCount) waiting to reach your iPhone")
                        }
                    }
                }

                Section {
                    Toggle("Auto-clean synced", isOn: $retentionEnabled)
                    if retentionEnabled {
                        Picker("Keep days", selection: $retentionMaxDays) {
                            Text("Off").tag(0)
                            Text("30").tag(30)
                            Text("90").tag(90)
                            Text("180").tag(180)
                            Text("360").tag(360)
                        }
                        Picker("Max sessions", selection: $retentionMaxSessions) {
                            Text("Off").tag(0)
                            Text("50").tag(50)
                            Text("100").tag(100)
                            Text("200").tag(200)
                            Text("500").tag(500)
                        }
                        Picker("Max size", selection: $retentionMaxMegabytes) {
                            Text("Off").tag(0)
                            Text("100 MB").tag(100)
                            Text("250 MB").tag(250)
                            Text("500 MB").tag(500)
                            Text("1000 MB").tag(1000)
                        }
                    }
                    LabeledContent("On watch", value: storageSummary)
                } header: {
                    Text("Storage")
                } footer: {
                    Text("Automatically remove older sessions from this watch once they're safely on your iPhone. Your dives stay on iPhone and iCloud — this only frees watch space.")
                }

                #if targetEnvironment(simulator)
                Section {
                    Toggle("Depth sensor", isOn: $simDepthSensor)
                    Toggle("Action button", isOn: $simActionButton)
                } header: {
                    Text("Simulator")
                } footer: {
                    Text("Fake device capabilities to preview the non-Ultra flows. Restart the app after changing. Simulator only.")
                }
                #endif
            }
            .navigationTitle("Settings")
            .task { storage = session.storageTotals() }
            .onChange(of: retentionEnabled) { applyRetention() }
            .onChange(of: retentionMaxDays) { applyRetention() }
            .onChange(of: retentionMaxSessions) { applyRetention() }
            .onChange(of: retentionMaxMegabytes) { applyRetention() }
        }
    }
}
