import SwiftUI
import AuthenticationServices
import Strava

/// Account settings: connect or disconnect Strava.
struct SettingsView: View {
    @Environment(StravaAuthManager.self) private var strava
    @State private var isConnecting = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
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
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
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
