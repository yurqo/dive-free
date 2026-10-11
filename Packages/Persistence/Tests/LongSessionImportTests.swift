import Foundation
import SwiftData
import Testing
import Domain
@testable import Persistence

@Suite("Long-session import")
@MainActor
struct LongSessionImportTests {
    @Test("a four-hour recording is saved intact and duplicate delivery preserves phone edits")
    func savesFullRecording() throws {
        let store = try DiveStore(inMemory: true)
        let start = Date(timeIntervalSince1970: 1_791_707_000)
        let duration = 4 * 3600
        let original = DiveSession(
            startTime: start, endTime: start.addingTimeInterval(Double(duration)),
            dives: (0..<60).map { index in
                let offset = index * 230
                return Dive(startTime: start.addingTimeInterval(Double(offset)),
                            endTime: start.addingTimeInterval(Double(offset + 90)), maxDepthMeters: 5.8,
                            samples: (0...90).map {
                    DepthSample(timestamp: start.addingTimeInterval(Double(offset + $0)), depthMeters: Double($0 % 6))
                })
            },
            markers: (0..<10).map {
                EventMarker(timestamp: start.addingTimeInterval(Double($0 * 200)), kind: .note,
                            text: "Reef", audioFileName: "voice-\($0).m4a", title: "Note", transcript: "Transcript")
            },
            track: (0...duration).map {
                TrackPoint(timestamp: start.addingTimeInterval(Double($0)),
                           location: GeoPoint(latitude: -8.3 + Double($0) / 1_000_000, longitude: 115.66, horizontalAccuracy: 4))
            },
            heartRateSamples: stride(from: 0, through: duration, by: 5).map {
                HeartRateSample(timestamp: start.addingTimeInterval(Double($0)), bpm: 80)
            },
            temperatureSamples: stride(from: 0, through: duration, by: 5).map {
                TemperatureSample(timestamp: start.addingTimeInterval(Double($0)), celsius: 28)
            }, locationName: "Bali"
        )
        let importer = SessionImporter(context: store.container.mainContext)
        #expect(try importer.importSession(original))
        let reader = ModelContext(store.container)
        let record = try #require(reader.fetch(FetchDescriptor<SessionRecord>()).first)
        let saved = record.toDomain()
        #expect(saved.id == original.id)
        #expect(saved.track == original.track)
        // SwiftData's to-many relationships have no ordering guarantee.
        #expect(saved.dives.sorted { $0.startTime < $1.startTime } == original.dives)
        #expect(saved.heartRateSamples == original.heartRateSamples)
        #expect(saved.temperatureSamples == original.temperatureSamples)
        #expect(saved.markers.sorted { $0.timestamp < $1.timestamp } == original.markers)
        record.title = "My Bali session"
        try reader.save()
        #expect(try !importer.importSession(original))
        let reread = ModelContext(store.container)
        let records = try reread.fetch(FetchDescriptor<SessionRecord>())
        #expect(records.count == 1)
        #expect(records[0].title == "My Bali session")
    }
}
