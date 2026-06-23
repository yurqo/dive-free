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
    ]
}

/// Convenience wrapper for building a container, primarily for tests and previews.
public struct DiveStore {
    public let container: ModelContainer

    public init(inMemory: Bool = false) throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        container = try ModelContainer(
            for: Schema(DiveSchema.models),
            configurations: configuration
        )
    }
}
