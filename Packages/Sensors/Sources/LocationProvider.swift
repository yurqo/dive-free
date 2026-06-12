import Foundation
import CoreLocation
import Domain

/// Source of location for a session: a one-shot fix for tagging where it
/// happened, plus a continuous stream for building the surface track.
/// Abstracted so `SessionManager` can be tested with a stub instead of real GPS.
public protocol LocationProviding: Sendable {
    /// Best-effort current location, or `nil` if unavailable or permission denied.
    /// GPS doesn't work underwater, so callers should request this at the surface.
    func currentLocation() async -> GeoPoint?

    /// A stream of surface GPS fixes for the session's track. Yields fixes as
    /// they arrive and ends when the consuming task is cancelled.
    func locationUpdates() -> AsyncStream<GeoPoint>
}

public extension LocationProviding {
    /// Default: a one-element stream from `currentLocation()`, so a provider that
    /// only knows a single fix still produces a (degenerate) track.
    func locationUpdates() -> AsyncStream<GeoPoint> {
        AsyncStream { continuation in
            let task = Task {
                if let point = await currentLocation() { continuation.yield(point) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// CoreLocation-backed provider. Uses `CLLocationUpdate.liveUpdates`, which
/// requests when-in-use authorization as needed.
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

    public func locationUpdates() -> AsyncStream<GeoPoint> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    for try await update in CLLocationUpdate.liveUpdates() {
                        if Task.isCancelled { break }
                        if update.authorizationDenied { break }
                        if let location = update.location {
                            continuation.yield(GeoPoint(
                                latitude: location.coordinate.latitude,
                                longitude: location.coordinate.longitude
                            ))
                        }
                    }
                } catch {}
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
