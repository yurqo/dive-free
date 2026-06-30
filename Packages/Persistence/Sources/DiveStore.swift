import Foundation
import SwiftData

/// Owns the SwiftData `ModelContainer` and exposes the schema to the apps.
public enum DiveSchema {
    /// Every persisted model type. Pass to `.modelContainer(for:)` in SwiftUI.
    public static let models: [any PersistentModel.Type] = [
        SessionRecord.self,
        DiveRecord.self,
        MarkerRecord.self,
        CustomMarkerRecord.self,
        Spot.self,
        PhotoRecord.self,
        Trip.self,
    ]

    /// The app's private CloudKit container for cross-device sync (#168),
    /// provisioned on the `org.yurko.divefree` App ID. Only the iPhone/iPad app
    /// enables it; the Watch stays WatchConnectivity-only and local.
    public static let cloudKitContainerID = "iCloud.org.yurko.divefree"
}

/// Convenience wrapper for building a container, used by the apps, tests, and previews.
public struct DiveStore {
    public let container: ModelContainer

    /// - Parameters:
    ///   - inMemory: ephemeral store (tests/previews).
    ///   - cloudKitContainerID: when non-nil, mirror the store to this private
    ///     CloudKit container (#168). Nil → a strictly local store (the Watch,
    ///     tests, and the iPhone when the user turns iCloud Sync off).
    public init(inMemory: Bool = false, cloudKitContainerID: String? = nil) throws {
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        } else if let cloudKitContainerID {
            configuration = ModelConfiguration(cloudKitDatabase: .private(cloudKitContainerID))
        } else {
            // Explicitly local: don't let `.automatic` pick up the iCloud
            // entitlement on the Watch, or when the user has opted out.
            configuration = ModelConfiguration(cloudKitDatabase: .none)
        }
        container = try ModelContainer(
            for: Schema(DiveSchema.models),
            configurations: configuration
        )
    }
}
