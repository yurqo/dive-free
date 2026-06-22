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

private extension GeoPoint {
    /// Maps a `CLLocation` to a `GeoPoint`, carrying horizontal accuracy when
    /// CoreLocation reports a valid (non-negative) value.
    init(_ location: CLLocation) {
        self.init(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            horizontalAccuracy: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil
        )
    }
}

/// User-controlled GPS precision (the toggle lives in watch Settings). High
/// precision uses `kCLLocationAccuracyBest` for the most accurate dive-spot pins
/// and surface track; the default trades down to ~10 m to save battery. Read
/// fresh at each session start, so toggling it takes effect on your next dive —
/// no restart needed.
public enum GPSPrecision {
    /// `@AppStorage`/`UserDefaults` key for the high-precision toggle.
    public static let highPrecisionKey = "highPrecisionGPS"

    /// Whether best-accuracy GPS is enabled; `false` (battery-saving) when unset.
    public static var isHighPrecision: Bool {
        UserDefaults.standard.bool(forKey: highPrecisionKey)
    }

    /// `CLLocationManager.desiredAccuracy` for the current setting.
    static var desiredAccuracy: CLLocationAccuracy {
        isHighPrecision ? kCLLocationAccuracyBest : kCLLocationAccuracyNearestTenMeters
    }
}

/// CoreLocation-backed provider. Pins GPS accuracy explicitly via a classic
/// `CLLocationManager` (the modern `CLLocationUpdate.liveUpdates` API exposes no
/// accuracy controls) at the precision chosen in Settings (`GPSPrecision`):
/// best accuracy when high-precision is on, ~10 m otherwise. Fitness activity
/// type, no distance filter, and auto-pause disabled so it keeps fixing while a
/// diver bobs (near-)stationary at the surface.
///
/// Intended to be used from the main actor (its sole production caller is the
/// `@MainActor SessionManager`); the per-stream `CLLocationManager` is created
/// on the calling thread, and its teardown hops to the main actor.
public struct CoreLocationProvider: LocationProviding {
    public init() {}

    public func currentLocation() async -> GeoPoint? {
        // First valid fix wins; returning drops the iterator, which terminates
        // the stream and tears the manager down.
        for await point in locationUpdates() {
            return point
        }
        return nil
    }

    public func locationUpdates() -> AsyncStream<GeoPoint> {
        AsyncStream { continuation in
            let delegate = LocationStreamDelegate(continuation: continuation)
            continuation.onTermination = { _ in delegate.stop() }
            delegate.start()
        }
    }
}

/// Bridges one `CLLocationManager`'s delegate callbacks to one `AsyncStream`
/// continuation. One instance per stream so concurrent consumers stay
/// independent, mirroring the old per-call `liveUpdates()` model.
private final class LocationStreamDelegate: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    private let manager = CLLocationManager()
    private let continuation: AsyncStream<GeoPoint>.Continuation

    init(continuation: AsyncStream<GeoPoint>.Continuation) {
        self.continuation = continuation
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = GPSPrecision.desiredAccuracy
        manager.activityType = .fitness
        manager.distanceFilter = kCLDistanceFilterNone
        #if !os(watchOS)
        // Don't let CoreLocation pause updates when it thinks we're stationary —
        // a diver resting at the surface still needs a live track.
        manager.pausesLocationUpdatesAutomatically = false
        #endif
        // NB: deliberately *not* setting `allowsBackgroundLocationUpdates` on
        // watchOS — it requires a `location` background mode the watch target
        // doesn't declare and traps without it ("CLClientIsBackgroundable").
        // The active HKWorkoutSession already grants the runtime that keeps GPS
        // fixes flowing while a session records.
    }

    func start() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    func stop() {
        continuation.finish()
        // CLLocationManager isn't thread-safe and onTermination can fire on any
        // thread; tear it down on the main actor where it was created.
        Task { @MainActor in
            manager.stopUpdatingLocation()
            manager.delegate = nil
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for location in locations where location.horizontalAccuracy >= 0 {
            continuation.yield(GeoPoint(location))
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        // Transient failures (e.g. brief signal loss as the wrist goes under)
        // shouldn't end the stream — CoreLocation keeps retrying. Only a denied
        // authorization ends it (handled in didChangeAuthorization).
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .denied, .restricted:
            continuation.finish()
        default:
            break
        }
    }
}
