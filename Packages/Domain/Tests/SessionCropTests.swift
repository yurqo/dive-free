import Foundation
import Testing
@testable import Domain

@Suite("SessionCrop")
struct SessionCropTests {
    // MARK: - Fixtures

    /// A `Date` `t` seconds past the epoch.
    private func d(_ t: Double) -> Date { Date(timeIntervalSince1970: t) }

    private func track(_ ts: [Double]) -> [TrackPoint] {
        ts.map { TrackPoint(timestamp: d($0), location: GeoPoint(latitude: 0, longitude: 0)) }
    }

    private func hr(_ ts: [Double]) -> [HeartRateSample] {
        ts.map { HeartRateSample(timestamp: d($0), bpm: 60) }
    }

    private func temp(_ ts: [Double]) -> [TemperatureSample] {
        ts.map { TemperatureSample(timestamp: d($0), celsius: 20) }
    }

    private func marker(_ t: Double, audio: Bool = false) -> EventMarker {
        EventMarker(timestamp: d(t), kind: .note, audioFileName: audio ? "note.m4a" : nil)
    }

    private func dive(_ start: Double, _ end: Double) -> Dive {
        Dive(startTime: d(start), endTime: d(end), maxDepthMeters: 10)
    }

    // MARK: - Trimming surface tails

    @Test("trims leading + trailing surface tails; keeps in-range series")
    func trimsTails() {
        // Session spans 0…100, one dive 40…60. Crop to 20…80.
        let session = DiveSession(
            startTime: d(0),
            endTime: d(100),
            dives: [dive(40, 60)],
            markers: [marker(10), marker(50), marker(90)],
            track: track([0, 20, 50, 80, 100]),
            heartRateSamples: hr([5, 30, 70, 95]),
            temperatureSamples: temp([15, 45, 85])
        )
        let result = session.cropped(to: d(20)...d(80))

        #expect(result.session.track.map(\.timestamp) == [d(20), d(50), d(80)])
        #expect(result.droppedTrackPoints == 2) // t=0 and t=100
        #expect(result.session.heartRateSamples.map(\.timestamp) == [d(30), d(70)])
        #expect(result.droppedHeartRateSamples == 2) // t=5 and t=95
        #expect(result.session.temperatureSamples.map(\.timestamp) == [d(45)])
        #expect(result.droppedTemperatureSamples == 2) // t=15 and t=85
        #expect(result.session.markers.map(\.timestamp) == [d(50)])
        #expect(result.droppedMarkers.map(\.timestamp) == [d(10), d(90)])
    }

    @Test("boundary points exactly at newStart / newEnd are kept (inclusive)")
    func inclusiveBounds() {
        let session = DiveSession(
            startTime: d(0),
            endTime: d(100),
            track: track([20, 80]),          // exactly on the edges
            heartRateSamples: hr([20, 80]),
            temperatureSamples: temp([20, 80])
        )
        let result = session.cropped(to: d(20)...d(80))
        #expect(result.session.track.count == 2)
        #expect(result.droppedTrackPoints == 0)
        #expect(result.session.heartRateSamples.count == 2)
        #expect(result.session.temperatureSamples.count == 2)
    }

    // MARK: - Markers at the edge + audio callout

    @Test("marker on the edge kept; just-outside dropped and carries hasAudio")
    func markerEdgeAndAudio() {
        let session = DiveSession(
            startTime: d(0),
            endTime: d(100),
            markers: [
                marker(20),                 // on the start edge → kept
                marker(19.999, audio: true) // just before → dropped, has audio
            ]
        )
        let result = session.cropped(to: d(20)...d(80))
        #expect(result.session.markers.map(\.timestamp) == [d(20)])
        #expect(result.droppedMarkers.count == 1)
        #expect(result.droppedMarkers.first?.timestamp == d(19.999))
        #expect(result.droppedMarkers.contains { $0.hasAudio })
    }

    // MARK: - Never cuts a dive

    @Test("range inside dives is clamped to firstDiveStart / lastDiveEnd")
    func neverCutsDive() {
        // Dives at 40…60 and 70…90. A crop range 50…80 would slice both dives.
        let session = DiveSession(
            startTime: d(0),
            endTime: d(120),
            dives: [dive(40, 60), dive(70, 90)],
            heartRateSamples: hr([45, 55, 75, 85]), // all in-dive samples
            temperatureSamples: temp([50, 80])
        )
        let result = session.cropped(to: d(50)...d(80))

        // Clamped to the dive span: start = first dive start, end = last dive end.
        #expect(result.session.startTime == d(40))
        #expect(result.session.endTime == d(90))
        // All dives survive intact.
        #expect(result.session.dives == session.dives)
        // No in-dive samples were dropped.
        #expect(result.droppedHeartRateSamples == 0)
        #expect(result.droppedTemperatureSamples == 0)
        #expect(result.session.heartRateSamples.count == 4)
    }

    // MARK: - Zero-dive sessions crop freely

    @Test("a zero-dive session crops to an arbitrary sub-range")
    func zeroDiveFreeCrop() {
        let session = DiveSession(
            startTime: d(0),
            endTime: d(100),
            track: track([0, 25, 50, 75, 100])
        )
        let result = session.cropped(to: d(25)...d(75))
        #expect(result.session.startTime == d(25))
        #expect(result.session.endTime == d(75))
        #expect(result.session.track.map(\.timestamp) == [d(25), d(50), d(75)])
        #expect(result.droppedTrackPoints == 2)
    }

    // MARK: - Bounds updated, everything else preserved

    @Test("startTime / endTime updated; unrelated fields unchanged")
    func preservesUnrelatedFields() {
        let weather = DiveWeather(weatherCode: 0, windSpeedKmh: 12)
        let uuid = UUID()
        let id = UUID()
        let session = DiveSession(
            id: id,
            startTime: d(0),
            endTime: d(100),
            dives: [dive(40, 60)],
            track: track([0, 50, 100]),
            weather: weather,
            activeEnergyKilocalories: 123.4,
            workoutUUID: uuid
        )
        let result = session.cropped(to: d(20)...d(80))
        #expect(result.session.startTime == d(20))
        #expect(result.session.endTime == d(80))
        #expect(result.session.dives == session.dives)
        #expect(result.session.weather == weather)
        #expect(result.session.activeEnergyKilocalories == 123.4)
        #expect(result.session.workoutUUID == uuid)
        #expect(result.session.id == id)
    }

    // MARK: - Degenerate / out-of-bounds input

    @Test("a range entirely before the session is clamped to a valid in-session span")
    func rangeBeforeSessionClampsAndKeepsDives() throws {
        let session = DiveSession(
            startTime: d(0),
            endTime: d(100),
            dives: [dive(40, 60)],
            track: track([0, 50, 100])
        )
        // Both bounds fall before the session entirely.
        let result = session.cropped(to: d(-100)...d(-50))
        // Result stays a valid range and never cuts the dive: clamped to
        // [startTime, lastDiveEnd].
        let endTime = try #require(result.session.endTime)
        #expect(result.session.startTime <= endTime)
        #expect(result.session.startTime == d(0))
        #expect(endTime == d(60))
        #expect(result.session.dives == session.dives)
    }

    @Test("a zero-width range still preserves dives and yields a valid span")
    func zeroWidthRangeKeepsDives() throws {
        let session = DiveSession(
            startTime: d(0),
            endTime: d(100),
            dives: [dive(40, 60)],
            track: track([0, 50, 100])
        )
        // Empty (zero-width) but valid range inside the dive.
        let result = session.cropped(to: d(50)...d(50))
        let endTime = try #require(result.session.endTime)
        #expect(result.session.startTime <= endTime)
        // Clamped out to the dive span so no dive is cut.
        #expect(result.session.startTime == d(40))
        #expect(endTime == d(60))
        #expect(result.session.dives == session.dives)
    }

    @Test("a zero-width range on a zero-dive session yields a valid degenerate span")
    func zeroWidthRangeNoDives() throws {
        let session = DiveSession(startTime: d(0), endTime: d(100))
        let result = session.cropped(to: d(50)...d(50))
        let endTime = try #require(result.session.endTime)
        #expect(result.session.startTime <= endTime)
        // No dives to protect: the degenerate range is honoured as-is.
        #expect(result.session.startTime == d(50))
        #expect(endTime == d(50))
    }

    @Test("nil endTime is handled without crashing")
    func nilEndTime() {
        let session = DiveSession(startTime: d(0), endTime: nil, track: track([0]))
        let result = session.cropped(to: d(0)...d(50))
        #expect(result.session.startTime <= (result.session.endTime ?? result.session.startTime))
    }

    // MARK: - Bounds helpers

    @Test("bounds helpers return correct ranges with dives")
    func boundsWithDives() {
        let session = DiveSession(
            startTime: d(0),
            endTime: d(120),
            dives: [dive(40, 60), dive(70, 90)]
        )
        #expect(session.firstDiveStart == d(40))
        #expect(session.lastDiveEnd == d(90))
        #expect(session.croppableStartRange == d(0)...d(40))
        #expect(session.croppableEndRange == d(90)...d(120))
    }

    @Test("bounds helpers handle a zero-dive session")
    func boundsNoDives() {
        let session = DiveSession(startTime: d(0), endTime: d(100))
        #expect(session.firstDiveStart == nil)
        #expect(session.lastDiveEnd == nil)
        #expect(session.croppableStartRange == d(0)...d(100))
        #expect(session.croppableEndRange == d(0)...d(100))
    }

    @Test("bounds helpers stay valid with nil endTime")
    func boundsNilEndTime() {
        let session = DiveSession(startTime: d(0), endTime: nil)
        #expect(session.croppableStartRange == d(0)...d(0))
        #expect(session.croppableEndRange == d(0)...d(0))
        #expect(session.croppableStartRange.lowerBound <= session.croppableStartRange.upperBound)
        #expect(session.croppableEndRange.lowerBound <= session.croppableEndRange.upperBound)
    }
}
