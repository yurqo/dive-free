import Foundation
import CoreLocation
import Domain

/// Source of a one-shot location fix for tagging where a session happened.
/// Abstracted so `SessionManager` can be tested with a stub instead of real GPS.
public protocol LocationProviding: Sendable {
    /// Best-effort current location, or `nil` if unavailable or permission denied.
    /// GPS doesn't work underwater, so callers should request this at the surface.
    func currentLocation() async -> GeoPoint?
}

/// CoreLocation-backed provider. Uses `CLLocationUpdate.liveUpdates`, which
/// requests when-in-use authorization as needed and stops as soon as we have a
/// fix (we return on the first location).
public struct CoreLocationProvider: LocationProviding {
    public init() {}

    public func currentLocation() async -> GeoPoint? {
        do {
            for try await update in CLLocationUpdate.liveUpdates() {
                if update.authorizationDenied { return nil }
                if let location = update.location {
                    return GeoPoint(
                        latitude: location.coordinate.latitude,
                        longitude: location.coordinate.longitude
                    )
                }
            }
        } catch {
            return nil
        }
        return nil
    }
}
