import Foundation
import os

/// Remote app configuration fetched from the DiveFree Worker at launch. Today it
/// carries a single flag — the tip-jar kill-switch — but it's a general channel
/// for feature toggles that must be flippable without an App Store release.
struct AppConfig: Decodable {
    /// Server side of the "Support DiveFree" gate. The app ANDs this with the
    /// App Store Connect product availability; the feature ships dark and stays
    /// hidden until both are true. Absent/failed fetch → treated as `false`.
    let supportEnabled: Bool
}

/// Fetches `AppConfig`. Injectable so `SupportStore` can be tested/previewed with
/// a stub instead of the network.
protocol AppConfigProviding: Sendable {
    /// Returns the fetched config, or `nil` on any failure (offline, timeout,
    /// non-2xx, decode error) — the caller then keeps its last cached value.
    func fetch() async -> AppConfig?
}

/// Real provider: `GET /app-config` on the public Worker host, background-priority
/// and short-timeout so a slow/offline network can't delay launch.
struct WorkerAppConfig: AppConfigProviding {
    static let url = URL(string: "https://divefree.software-engineer.ing/app-config")!
    private let log = Logger(subsystem: "org.yurko.divefree", category: "AppConfig")

    func fetch() async -> AppConfig? {
        var request = URLRequest(url: Self.url)
        // Short cap (vs URLSession's 60 s default) — this runs at launch and must
        // never hold anything up; a miss just leaves the cached value in place.
        request.timeoutInterval = 5
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(code) else {
                log.error("app-config fetch rejected (HTTP \(code, privacy: .public)).")
                return nil
            }
            return try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            log.error("app-config fetch failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
