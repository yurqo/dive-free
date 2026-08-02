import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import AuthenticationServices
import Domain
import Persistence
import Strava

/// Account settings: units, Strava connection, custom markers.
struct SettingsView: View {
    @Environment(StravaAuthManager.self) private var strava
    @Environment(SupportStore.self) private var support
    @Environment(\.syncManager) private var sync
    @Environment(\.modelContext) private var modelContext
    @State private var isConnecting = false
    @State private var errorMessage: String?

    // Backup & restore UI state.
    @State private var showExportSheet = false
    @State private var showRestoreImporter = false
    @State private var isRestoring = false
    @State private var restoreResult: BackupService.RestoreResult?
    @State private var backupErrorMessage: String?

    // Units preference — each dimension stored independently so the Custom
    // pickers bind directly; defaults follow the device region until chosen.
    @AppStorage(UnitPreference.Key.mode) private var unitModeRaw = UnitPreference.regionDefault.mode.rawValue
    @AppStorage(UnitPreference.Key.depth) private var depthRaw = UnitPreference.regionDefault.customDepth.rawValue
    @AppStorage(UnitPreference.Key.distance) private var distanceRaw = UnitPreference.regionDefault.customDistance.rawValue
    @AppStorage(UnitPreference.Key.temperature) private var temperatureRaw = UnitPreference.regionDefault.customTemperature.rawValue
    @AppStorage(UnitPreference.Key.windSpeed) private var windSpeedRaw = UnitPreference.regionDefault.windSpeed.rawValue
    // iCloud Sync opt-out (#168). Applied at next launch — the SwiftData container
    // is built in DiveFreeApp.init.
    @AppStorage(AppStorageKey.iCloudSyncEnabled) private var iCloudSyncEnabled = true

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    UserGuideView()
                } label: {
                    Label("User Guide", systemImage: "book")
                }
            }
            unitsSection
            Section {
                NavigationLink {
                    DiveDetectionSettingsView()
                } label: {
                    Label("Dive detection", systemImage: "waveform.path.ecg")
                }
            } footer: {
                Text("Tune when a descent counts as a dive. Syncs to your watch and applies to your next session.")
            }
            // Recovery is its own row rather than a section inside Dive detection: it's
            // the setting a diver revisits between sessions. Same stored blob, same sync.
            Section {
                NavigationLink {
                    RecoverySettingsView()
                } label: {
                    Label("Recovery", systemImage: "lungs")
                }
            } footer: {
                Text("Set how long to rest between dives, and whether the watch hints when you're rested. Syncs to your watch and applies to your next session.")
            }
            iCloudSection
            backupSection
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

            // The tip jar appears only when both gates pass (products live in App
            // Store Connect AND the remote kill-switch is on) — the feature ships
            // dark and self-activates without an app update.
            if support.visibility.showPurchaseUI {
                Section {
                    NavigationLink {
                        SupportView()
                    } label: {
                        Label("Support DiveFree", systemImage: "cup.and.saucer")
                    }
                } footer: {
                    Text("DiveFree is free. If you'd like, you can leave a tip to keep it going.")
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showExportSheet) {
            ExportBackupView(context: modelContext)
        }
        .fileImporter(
            isPresented: $showRestoreImporter,
            allowedContentTypes: [.zip]
        ) { result in
            switch result {
            case .success(let url):
                isRestoring = true
                Task {
                    defer { isRestoring = false }
                    do {
                        restoreResult = try await BackupService.restoreBackup(from: url, context: modelContext)
                    } catch {
                        backupErrorMessage = restoreErrorMessage(for: error)
                    }
                }
            case .failure(let error):
                backupErrorMessage = restoreErrorMessage(for: error)
            }
        }
        .alert(
            "Restore Complete",
            isPresented: Binding(
                get: { restoreResult != nil },
                set: { if !$0 { restoreResult = nil } }
            ),
            presenting: restoreResult
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { result in
            Text(restoreSummaryMessage(result))
        }
        .alert(
            "Backup Failed",
            isPresented: Binding(
                get: { backupErrorMessage != nil },
                set: { if !$0 { backupErrorMessage = nil } }
            ),
            presenting: backupErrorMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    @ViewBuilder private var backupSection: some View {
        Section {
            Button {
                showExportSheet = true
            } label: {
                Label("Export Backup…", systemImage: "square.and.arrow.up.on.square")
            }
            .disabled(isRestoring)
            Button {
                showRestoreImporter = true
            } label: {
                HStack {
                    Label("Restore Backup…", systemImage: "square.and.arrow.down")
                    if isRestoring {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isRestoring)
        } header: {
            Text("Backup & Restore")
        } footer: {
            Text("Export everything — sessions, spots, trips, and your photo gallery — as a single .zip file to save in Files or another device. A lean backup keeps the file small; you can optionally add voice notes, photos, and videos. Restoring is additive: existing items are kept and duplicates are skipped. With iCloud Sync on, a restore also propagates to your other devices.")
        }
    }

    // MARK: - Backup messages

    /// A friendly, pluralized summary of a completed restore.
    ///
    /// Each line uses a plain interpolated count (e.g. "3 sessions"), which the String
    /// Catalog can pluralize per-language via its own plural variations — no
    /// `^[…](inflect:)` automatic-grammar markup, which is the inflection pitfall.
    private func restoreSummaryMessage(_ result: BackupService.RestoreResult) -> String {
        let s = result.summary
        let imported = String(
            localized: "Imported \(s.sessionsImported) sessions (\(s.sessionsSkipped) already present)."
        )
        let spots = String(
            localized: "Added \(s.spotsCreated) spots and \(s.tripsCreated) trips."
        )
        let voiceNotes = String(
            localized: "Restored \(s.audioRestored) voice notes."
        )
        let photos = String(
            localized: "Restored \(s.photosRestored) photos (\(result.photosReimported) re-imported to Photos)."
        )
        var lines = [imported, spots, voiceNotes, photos]
        if result.photoAccessDenied {
            lines.append(String(
                localized: "Some photo originals couldn't be re-imported because Photos access was denied."
            ))
        }
        return lines.joined(separator: "\n")
    }

    /// Maps a restore failure to a user-facing message, translating the archive's
    /// typed errors into plain guidance.
    private func restoreErrorMessage(for error: Error) -> String {
        switch error {
        case BackupArchiveError.unsupportedVersion:
            return String(localized: "This backup was made by a newer version of Dive Free. Update the app and try again.")
        case BackupArchiveError.malformed:
            return String(localized: "This file isn't a valid Dive Free backup.")
        case ZipContainer.ZipError.malformed(let reason):
            // Include the parser's reason: it names exactly which check failed (e.g. EOCD
            // not found vs a write/permission error), which is what pins down a device-only
            // failure on an archive that reads fine everywhere else.
            return String(localized: "This backup file couldn't be read (\(reason)). Move it to \"On My iPhone\" in Files and try again.")
        case ZipContainer.ZipError.unsupportedEntry:
            return String(localized: "This backup uses a feature this version of Dive Free can't read. Update the app and try again.")
        case ZipContainer.ZipError.crcMismatch:
            return String(localized: "This backup file is corrupted — a file inside it failed its integrity check. Try transferring or exporting it again.")
        case ZipContainer.ZipError.entryTooLarge, ZipContainer.ZipError.tooManyEntries:
            return String(localized: "This backup is too large for Dive Free to restore.")
        default:
            // Never a dead end: surface the underlying cause (e.g. a SwiftData/CloudKit
            // save failure or a filesystem error) so the next attempt is diagnosable.
            return String(localized: "Couldn't restore the backup. Please try again. (\(error.localizedDescription))")
        }
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
            // Wind speed is independent of the mode (metric wind is shown as
            // either km/h or m/s), so it's always selectable.
            Picker("Wind speed", selection: $windSpeedRaw) {
                Text("km/h").tag(WindSpeedUnit.kmh.rawValue)
                Text("m/s").tag(WindSpeedUnit.ms.rawValue)
                Text("mph").tag(WindSpeedUnit.mph.rawValue)
                Text("Knots").tag(WindSpeedUnit.knots.rawValue)
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
        .onChange(of: windSpeedRaw) { syncUnits() }
    }

    @ViewBuilder private var iCloudSection: some View {
        Section {
            Toggle("iCloud Sync", isOn: $iCloudSyncEnabled)
            if iCloudSyncEnabled { CloudKitSyncStatusRows() }
        } header: {
            Text("iCloud")
        } footer: {
            Text("Syncs your dive log across your devices through your private iCloud account. Your data stays in your iCloud and isn't accessible to us. Changes take effect next time you open the app.")
        }
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
            errorMessage = String(localized: "Strava access was denied.")
        } catch StravaOAuth.CallbackError.stateMismatch {
            errorMessage = String(localized: "Strava sign-in couldn't be verified (security check failed). Please try again.")
        } catch StravaOAuth.CallbackError.missingCode {
            errorMessage = String(localized: "Strava didn't return a sign-in code. Please try again.")
        } catch let StravaError.server(status) {
            // A non-2xx from the token proxy during the code→token exchange —
            // the status pins down whether the token step is what's failing.
            errorMessage = String(localized: "Strava sign-in failed (error \(status)). Please try again.")
        } catch is ASWebAuthenticationSessionError {
            // Any other web-auth failure (e.g. .presentationContextNotProvided /
            // .presentationContextInvalid) — the sign-in window couldn't open.
            errorMessage = String(localized: "Couldn't open the Strava sign-in window. Please try again.")
        } catch {
            errorMessage = String(localized: "Couldn't connect to Strava. Please try again. (\(error.localizedDescription))")
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
    .environment(StravaAuthManager(store: InMemoryTokenStore(), webAuth: ASWebAuthenticationProvider()))
    .environment(CloudKitSyncMonitor())
    .environment(SupportStore())
}
