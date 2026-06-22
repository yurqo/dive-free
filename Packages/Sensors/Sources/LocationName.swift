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

    private static func reverseGeocode(latitude: Double, longitude: Double) async -> String? {
        await withCheckedContinuation { continuation in
            let location = CLLocation(latitude: latitude, longitude: longitude)
            // CLGeocoder is soft-deprecated on OS 26 (use MKReverseGeocodingRequest),
            // but that's 26+-only; CLGeocoder still works on our watchOS 11 floor.
            CLGeocoder().reverseGeocodeLocation(location) { placemarks, _ in
                let placemark = placemarks?.first
                continuation.resume(
                    returning: placemark?.locality
                        ?? placemark?.subAdministrativeArea
                        ?? placemark?.administrativeArea
                        ?? placemark?.country
                )
            }
        }
    }
}
