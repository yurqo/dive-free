import Foundation

/// Proximity rules for assigning a session to a dive spot: a session joins the
/// nearest existing spot within a radius, otherwise it seeds a new one. Pure and
/// testable; the SwiftData wiring lives in the persistence layer.
public enum SpotProximity {
    /// Default join radius (meters). Sessions within this of a spot's center join it.
    public static let defaultRadiusMeters = 250.0

    /// Index of the nearest candidate within `radiusMeters` of `point`, or `nil`
    /// when none is close enough.
    public static func nearestIndex(
        to point: GeoPoint,
        among candidates: [GeoPoint],
        withinMeters radiusMeters: Double = defaultRadiusMeters
    ) -> Int? {
        var best: (index: Int, distance: Double)?
        for (index, candidate) in candidates.enumerated() {
            let distance = point.distance(to: candidate)
            guard distance <= radiusMeters else { continue }
            if best == nil || distance < best!.distance { best = (index, distance) }
        }
        return best?.index
    }

    /// Centroid of the given points (mean lat/lon), or `nil` when empty. Used as a
    /// spot's center, recomputed as sessions join.
    public static func center(of points: [GeoPoint]) -> GeoPoint? {
        guard !points.isEmpty else { return nil }
        let latitude = points.map(\.latitude).reduce(0, +) / Double(points.count)
        let longitude = points.map(\.longitude).reduce(0, +) / Double(points.count)
        return GeoPoint(latitude: latitude, longitude: longitude)
    }
}
