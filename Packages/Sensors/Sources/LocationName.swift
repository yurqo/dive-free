import Foundation
import CoreLocation

/// Best-effort reverse geocoding of a coordinate to a short, human-readable area
/// name (locality / region), used to label saved sessions in the list.
///
/// Time-boxed so a slow or offline geocoder never hangs the save flow; returns
/// `nil` on timeout, failure, or when nothing useful resolves.
public enum LocationName {
    public static func resolve(
        latitude: Double,
        longitude: Double,
        timeout: Duration = .seconds(5)
    ) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask { await reverseGeocode(latitude: latitude, longitude: longitude) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            // First to finish wins — the geocode result, or nil once the timeout
            // fires — then cancel the loser.
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    /// Best-effort country (name + ISO code) for a coordinate (#147), time-boxed
    /// like `resolve`. `nil` on timeout/failure or when no country resolves.
    public static func resolveCountry(
        latitude: Double,
        longitude: Double,
        timeout: Duration = .seconds(5)
    ) async -> (name: String, code: String)? {
        await withTaskGroup(of: (name: String, code: String)?.self) { group in
            group.addTask { await reverseGeocodeCountry(latitude: latitude, longitude: longitude) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private static func reverseGeocode(latitude: Double, longitude: Double) async -> String? {
        let mark = await placemark(latitude: latitude, longitude: longitude)
        return mark?.locality
            ?? mark?.subAdministrativeArea
            ?? mark?.administrativeArea
            ?? mark?.country
    }

    private static func reverseGeocodeCountry(latitude: Double, longitude: Double) async -> (name: String, code: String)? {
        guard let mark = await placemark(latitude: latitude, longitude: longitude),
              let country = mark.country, let code = mark.isoCountryCode else { return nil }
        return (country, code)
    }

    /// Reverse-geocodes a coordinate to its first placemark, keeping the geocoder
    /// alive across the suspension: a bare `CLGeocoder()` temporary deallocates as
    /// soon as the call returns, cancelling the request so the completion (and our
    /// continuation) never fires. Referencing it *after* the await pins it in the
    /// async frame without capturing a non-Sendable type in the @Sendable handler.
    private static func placemark(latitude: Double, longitude: Double) async -> CLPlacemark? {
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: latitude, longitude: longitude)
        // CLGeocoder is soft-deprecated on OS 26 (use MKReverseGeocodingRequest),
        // but that's 26+-only; CLGeocoder still works on our watchOS 11 floor.
        let result: CLPlacemark? = await withCheckedContinuation { continuation in
            geocoder.reverseGeocodeLocation(location) { placemarks, _ in
                continuation.resume(returning: placemarks?.first)
            }
        }
        withExtendedLifetime(geocoder) {}
        return result
    }
}
