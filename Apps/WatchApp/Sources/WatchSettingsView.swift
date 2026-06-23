import SwiftUI
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
        }
    }
}
