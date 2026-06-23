import Foundation
import SwiftData
import Domain

/// Assigns sessions to dive spots: each located session joins the nearest spot
/// within `radiusMeters`, or seeds a new spot named from its reverse-geocoded
/// area (`locationName`). A spot's center is the mean of its sessions' locations.
///
/// Idempotent — only touches sessions that have a location but no spot yet — so it
/// doubles as the migration backfill for existing sessions and the per-launch pass
/// that picks up newly imported ones.
@MainActor
public struct SpotAssigner {
    private let context: ModelContext
    private let radiusMeters: Double

    public init(context: ModelContext, radiusMeters: Double = SpotProximity.defaultRadiusMeters) {
        self.context = context
        self.radiusMeters = radiusMeters
    }

    /// Assigns every located, spot-less session. Returns the number assigned.
    @discardableResult
    public func assignUnassignedSessions() throws -> Int {
        let unassigned = try context.fetch(FetchDescriptor<SessionRecord>())
            .filter { $0.spot == nil && $0.latitude != nil && $0.longitude != nil }
            .sorted { $0.startTime < $1.startTime }
        guard !unassigned.isEmpty else { return 0 }

        var spots = try context.fetch(FetchDescriptor<Spot>())
        var assigned = 0
        for session in unassigned {
            guard let latitude = session.latitude, let longitude = session.longitude else { continue }
            let point = GeoPoint(latitude: latitude, longitude: longitude)
            let centers = spots.map { GeoPoint(latitude: $0.centerLatitude, longitude: $0.centerLongitude) }

            if let index = SpotProximity.nearestIndex(to: point, among: centers, withinMeters: radiusMeters) {
                session.spot = spots[index]
                recenter(spots[index])
            } else {
                let spot = Spot(
                    name: session.locationName ?? "Dive spot",
                    centerLatitude: latitude,
                    centerLongitude: longitude
                )
                context.insert(spot)
                session.spot = spot
                spots.append(spot)
            }
            assigned += 1
        }
        try context.save()
        return assigned
    }

    /// Merges `source` into `target`: moves its sessions and photos over,
    /// recomputes the target's center, and deletes the now-empty source spot.
    public func merge(_ source: Spot, into target: Spot) throws {
        guard source.persistentModelID != target.persistentModelID else { return }
        // Snapshot the relationship arrays — reassigning mutates them as we go.
        for session in Array(source.sessions) { session.spot = target }
        for photo in Array(source.photos) { photo.spot = target }
        recenter(target)
        context.delete(source)
        try context.save()
    }

    /// Reassigns `session` to `spot`, recomputing both the new and previous spots'
    /// centers.
    public func reassign(_ session: SessionRecord, to spot: Spot) throws {
        let previous = session.spot
        guard previous?.persistentModelID != spot.persistentModelID else { return }
        session.spot = spot
        recenter(spot)
        if let previous { recenter(previous) }
        try context.save()
    }

    /// Recomputes a spot's center as the mean of its sessions' locations.
    private func recenter(_ spot: Spot) {
        let points = spot.sessions.compactMap { session -> GeoPoint? in
            guard let latitude = session.latitude, let longitude = session.longitude else { return nil }
            return GeoPoint(latitude: latitude, longitude: longitude)
        }
        guard let center = SpotProximity.center(of: points) else { return }
        spot.centerLatitude = center.latitude
        spot.centerLongitude = center.longitude
    }
}
