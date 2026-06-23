import SwiftUI
import AuthenticationServices
import Domain
import Strava

/// Account settings: units, Strava connection, custom markers.
struct SettingsView: View {
    @Environment(StravaAuthManager.self) private var strava
    @Environment(\.syncManager) private var sync
    @State private var isConnecting = false
    @State private var errorMessage: String?

    // Units preference — each dimension stored independently so the Custom
    // pickers bind directly; defaults follow the device region until chosen.
    @AppStorage(UnitPreference.Key.mode) private var unitModeRaw = UnitPreference.regionDefault.mode.rawValue
    @AppStorage(UnitPreference.Key.depth) private var depthRaw = UnitPreference.regionDefault.customDepth.rawValue
    @AppStorage(UnitPreference.Key.distance) private var distanceRaw = UnitPreference.regionDefault.customDistance.rawValue
    @AppStorage(UnitPreference.Key.temperature) private var temperatureRaw = UnitPreference.regionDefault.customTemperature.rawValue

    var body: some View {
        Form {
            unitsSection
            Section {
                if strava.isConnected {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button("Disconnect", role: .destructive) { strava.disconnect() }
                } else {
                    Button(action: { Task { await connect() } }) {
                        HStack {
                            Label("Connect Strava", systemImage: "link")
                            if isConnecting {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isConnecting)
                }
            } header: {
                Text("Strava")
            } footer: {
                Text("Connect your Strava account to export dive sessions as activities.")
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section {
                NavigationLink {
                    CustomMarkersView()
                } label: {
                    Label("Custom Markers", systemImage: "mappin.and.ellipse")
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private var unitsSection: some View {
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
                    Text("Metric (m/km)").tag(DistanceUnit.metric.rawValue)
                    Text("Imperial (ft/mi)").tag(DistanceUnit.imperial.rawValue)
                }
                Picker("Temperature", selection: $temperatureRaw) {
                    Text("Celsius").tag(TemperatureUnit.celsius.rawValue)
                    Text("Fahrenheit").tag(TemperatureUnit.fahrenheit.rawValue)
                }
            }
        } header: {
            Text("Units")
        } footer: {
            Text("Custom lets you mix units per measurement — e.g. meters for depth with Fahrenheit water temperature.")
        }
        .onChange(of: unitModeRaw) { syncUnits() }
        .onChange(of: depthRaw) { syncUnits() }
        .onChange(of: distanceRaw) { syncUnits() }
        .onChange(of: temperatureRaw) { syncUnits() }
    }

    /// Push the (just-written) units preference to the watch.
    private func syncUnits() {
        sync?.sendUnitPreference(.current)
    }

    private func connect() async {
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }
        do {
            try await strava.connect()
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // User dismissed the consent sheet — not an error worth surfacing.
        } catch StravaOAuth.CallbackError.denied {
            errorMessage = "Strava access was denied."
        } catch {
            errorMessage = "Couldn't connect to Strava. Please try again."
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
    .environment(StravaAuthManager(store: InMemoryTokenStore(), webAuth: ASWebAuthenticationProvider()))
}
