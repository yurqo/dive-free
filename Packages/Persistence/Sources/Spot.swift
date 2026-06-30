import Foundation
import SwiftData

/// A persistent dive spot: a place the diver has logged one or more sessions.
/// Sessions auto-assign to the nearest spot within a radius (else a new spot is
/// created), and the spot's center is the mean of its sessions' locations.
@Model
public final class Spot {
    // Optional/defaulted for CloudKit compatibility (#168); additive migration.
    public var id: UUID = UUID()
    public var name: String = ""
    public var centerLatitude: Double = 0
    public var centerLongitude: Double = 0
    public var createdAt: Date = Date()
    public var notes: String?
    /// Reverse-geocoded country name + ISO code (#147), backfilled from the spot
    /// center. Optional so existing rows migrate to nil and get backfilled.
    public var country: String?
    public var countryCode: String?
    /// The Photos folder (PHCollectionList) holding this spot's session albums
    /// (#145), nested under Dive Free ▸ Spots. Stored so the folder is reused and
    /// renamed (not duplicated) when the spot is renamed in-app.
    public var photosFolderIdentifier: String?

    @Relationship(deleteRule: .nullify, inverse: \SessionRecord.spot)
    public var sessions: [SessionRecord] = []

    /// Photos attached directly to the spot (not via a session). The spot's full
    /// gallery is these plus its sessions' photos.
    @Relationship(deleteRule: .nullify, inverse: \PhotoRecord.spot)
    public var photos: [PhotoRecord] = []

    public init(
        id: UUID = UUID(),
        name: String,
        centerLatitude: Double,
        centerLongitude: Double,
        createdAt: Date = Date(),
        notes: String? = nil,
        country: String? = nil,
        countryCode: String? = nil,
        sessions: [SessionRecord] = []
    ) {
        self.id = id
        self.name = name
        self.centerLatitude = centerLatitude
        self.centerLongitude = centerLongitude
        self.createdAt = createdAt
        self.notes = notes
        self.country = country
        self.countryCode = countryCode
        self.sessions = sessions
    }
}
