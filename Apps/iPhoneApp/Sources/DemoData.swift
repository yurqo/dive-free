#if DEBUG
import Foundation
import SwiftData
import Domain
import Persistence

/// DEBUG-only demo-data seeding for screenshot automation.
///
/// Populates an in-memory store with a small, hand-crafted set of sessions,
/// spots, and a trip at real, photogenic freediving locations so App Store
/// screenshots have believable content (depth charts, maps, stats, badges).
///
/// Everything here is wrapped in `#if DEBUG` and reached only via the
/// `--screenshot-demo` launch argument (see `DiveFreeApp`), so it is completely
/// absent from Release builds — the App Store binary never contains it.
///
/// **Deterministic:** all timestamps are computed relative to a fixed base date
/// (`baseDate`, 2026-06-01), never `Date()`, and every value is fixed — so each
/// run, on any device or locale, produces byte-identical content.
///
/// **Localized-safe:** titles/notes are intentionally left `nil` (the UI falls
/// back to date/area), so no English text leaks into non-English screenshots.
/// Location names are proper-noun place names, which read correctly in any
/// locale. Dates, numbers, and marker labels localize themselves.
enum DemoData {
    /// Fixed base date all fixtures are computed from. NOT `Date()` — keeps the
    /// seeded content identical across runs and locales.
    private static let baseDate: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = 1
        components.hour = 9
        components.minute = 0
        components.second = 0
        components.timeZone = TimeZone(identifier: "UTC")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }()

    /// A photogenic real dive location used to build a fixture session.
    private struct SpotFixture {
        let name: String
        let latitude: Double
        let longitude: Double
        let country: String
        let countryCode: String
    }

    // Real freediving spots. Names are proper nouns → safe across locales.
    private static let amed = SpotFixture(
        name: "Amed", latitude: -8.3402, longitude: 115.6870,
        country: "Indonesia", countryCode: "ID"
    )
    private static let blueHole = SpotFixture(
        name: "Blue Hole, Dahab", latitude: 28.5721, longitude: 34.5377,
        country: "Egypt", countryCode: "EG"
    )
    private static let faial = SpotFixture(
        name: "Faial, Azores", latitude: 38.5340, longitude: -28.6270,
        country: "Portugal", countryCode: "PT"
    )

    /// Builds the demo store contents and saves them. Idempotent per fresh
    /// (in-memory) context — call once against a new store.
    static func seed(into context: ModelContext) {
        // --- Spots ---------------------------------------------------------
        let amedSpot = Spot(
            name: amed.name,
            centerLatitude: amed.latitude,
            centerLongitude: amed.longitude,
            createdAt: baseDate,
            country: amed.country,
            countryCode: amed.countryCode
        )
        let dahabSpot = Spot(
            name: blueHole.name,
            centerLatitude: blueHole.latitude,
            centerLongitude: blueHole.longitude,
            createdAt: baseDate,
            country: blueHole.country,
            countryCode: blueHole.countryCode
        )
        context.insert(amedSpot)
        context.insert(dahabSpot)

        // --- Sessions ------------------------------------------------------
        // Session 1: Amed, day 0. Two dives, warm & clear.
        let session1 = makeSession(
            dayOffset: 0,
            fixture: amed,
            diveDepths: [5.5, 4.8],
            rating: 5,
            conditions: DiveConditions(
                visibility: .excellent,
                current: .light,
                surface: .calm,
                tide: .high,
                waterTemperatureCelsius: 28.0,
                airTemperatureCelsius: 30.0
            ),
            weather: DiveWeather(
                weatherCode: 0, windSpeedKmh: 8.0,
                windDirectionDegrees: 120, waveHeightMeters: 0.3
            ),
            markerKinds: [.wildlife, .photo]
        )

        // Session 2: Amed, day 1. Single dive, part of the same trip.
        let session2 = makeSession(
            dayOffset: 1,
            fixture: amed,
            diveDepths: [6.0],
            rating: 4,
            conditions: DiveConditions(
                visibility: .good,
                current: .moderate,
                surface: .calm,
                tide: .incoming,
                waterTemperatureCelsius: 27.5,
                airTemperatureCelsius: 29.0
            ),
            weather: DiveWeather(
                weatherCode: 1, windSpeedKmh: 12.0,
                windDirectionDegrees: 200, waveHeightMeters: 0.4
            ),
            markerKinds: [.photo]
        )

        // Session 3: Dahab Blue Hole, day 5. Two dives.
        let session3 = makeSession(
            dayOffset: 5,
            fixture: blueHole,
            diveDepths: [4.0, 5.2],
            rating: 5,
            conditions: DiveConditions(
                visibility: .excellent,
                // `WaterCurrent.none` (the "no current" case), NOT `Optional.none`
                // — a bare `.none` here resolves to nil and drops the value.
                current: WaterCurrent.none,
                surface: .calm,
                tide: .high,
                waterTemperatureCelsius: 24.0,
                airTemperatureCelsius: 27.0
            ),
            weather: DiveWeather(
                weatherCode: 0, windSpeedKmh: 6.0,
                windDirectionDegrees: 90, waveHeightMeters: 0.2
            ),
            markerKinds: [.wildlife]
        )

        // Session 4: Azores / Faial, day 9. Cooler, single dive.
        let session4 = makeSession(
            dayOffset: 9,
            fixture: faial,
            diveDepths: [4.5],
            rating: 4,
            conditions: DiveConditions(
                visibility: .good,
                current: .light,
                surface: .choppy,
                tide: .outgoing,
                waterTemperatureCelsius: 19.0,
                airTemperatureCelsius: 21.0
            ),
            weather: DiveWeather(
                weatherCode: 2, windSpeedKmh: 18.0,
                windDirectionDegrees: 270, waveHeightMeters: 0.8
            ),
            markerKinds: [.note]
        )

        for session in [session1, session2, session3, session4] {
            context.insert(session)
        }

        // --- Spot assignment ----------------------------------------------
        session1.spot = amedSpot
        session2.spot = amedSpot
        session3.spot = dahabSpot
        // session4 (Faial) intentionally left without a pre-created Spot object
        // beyond its own coordinates; assign a fresh spot so the map/name render.
        let faialSpot = Spot(
            name: faial.name,
            centerLatitude: faial.latitude,
            centerLongitude: faial.longitude,
            createdAt: baseDate,
            country: faial.country,
            countryCode: faial.countryCode
        )
        context.insert(faialSpot)
        session4.spot = faialSpot

        // --- Trip (groups the two Amed sessions) --------------------------
        let trip = Trip(
            // Proper-noun place name → locale-safe.
            name: amed.name,
            startDate: session1.startTime,
            endDate: session2.endTime ?? session2.startTime,
            createdAt: baseDate
        )
        context.insert(trip)
        session1.trip = trip
        session2.trip = trip

        try? context.save()
    }

    // MARK: - Fixture builders

    /// Builds one fully-populated `SessionRecord` for a spot on a given day.
    private static func makeSession(
        dayOffset: Int,
        fixture: SpotFixture,
        diveDepths: [Double],
        rating: Int,
        conditions: DiveConditions,
        weather: DiveWeather,
        markerKinds: [EventKind]
    ) -> SessionRecord {
        // Session starts at the base time, offset by whole days for determinism.
        let sessionStart = baseDate.addingTimeInterval(Double(dayOffset) * 86_400)

        var dives: [DiveRecord] = []
        var markers: [MarkerRecord] = []
        var temperatureSamples: [TemperatureSample] = []
        var markerCursor = 0

        // Space dives 8 minutes apart, each with a ~90 s smooth profile.
        var diveCursor = sessionStart.addingTimeInterval(120) // 2 min surface warm-up
        for depth in diveDepths {
            let profile = depthProfile(start: diveCursor, maxDepth: depth)
            let diveEnd = profile.last?.timestamp ?? diveCursor
            let dive = DiveRecord(
                startTime: diveCursor,
                endTime: diveEnd,
                maxDepthMeters: depth,
                samples: profile
            )
            dives.append(dive)

            // One water-temperature sample at the bottom of each dive.
            let bottom = diveCursor.addingTimeInterval(profile.count > 0 ? Double(profile.count) / 2 : 0)
            temperatureSamples.append(
                TemperatureSample(
                    timestamp: bottom,
                    celsius: conditions.waterTemperatureCelsius ?? 25.0
                )
            )

            // Attach a marker mid-dive (localized emoji/label via built-in kind).
            if markerCursor < markerKinds.count {
                markers.append(
                    MarkerRecord(
                        timestamp: diveCursor.addingTimeInterval(30),
                        kind: markerKinds[markerCursor].rawValue,
                        emoji: markerKinds[markerCursor].emoji,
                        label: markerKinds[markerCursor].label
                    )
                )
                markerCursor += 1
            }

            diveCursor = diveEnd.addingTimeInterval(480) // 8 min surface interval
        }

        // Any remaining marker kinds land as surface markers near the end.
        while markerCursor < markerKinds.count {
            markers.append(
                MarkerRecord(
                    timestamp: diveCursor.addingTimeInterval(60),
                    kind: markerKinds[markerCursor].rawValue,
                    emoji: markerKinds[markerCursor].emoji,
                    label: markerKinds[markerCursor].label
                )
            )
            markerCursor += 1
        }

        let sessionEnd = diveCursor
        let record = SessionRecord(
            startTime: sessionStart,
            endTime: sessionEnd,
            latitude: fixture.latitude,
            longitude: fixture.longitude,
            track: surfaceTrack(start: sessionStart, end: sessionEnd, fixture: fixture),
            heartRateSamples: heartRateSamples(start: sessionStart, end: sessionEnd),
            temperatureSamples: temperatureSamples,
            locationName: fixture.name,
            locationNameEdited: true, // proper-noun name; don't let geocoding clobber
            title: nil,               // fall back to date/area (locale-safe)
            notes: nil,               // no English text leaking into screenshots
            rating: rating,
            conditions: conditions,
            weather: weather,
            weatherFetched: true,
            smoothTrack: true,
            activeEnergyKilocalories: 120 + Double(dayOffset) * 5,
            dives: dives,
            markers: markers
        )
        return record
    }

    /// A smooth descent/ascent depth profile (1 Hz), triangular with an eased
    /// bottom, capped at `maxDepth`. Deterministic — depends only on inputs.
    private static func depthProfile(start: Date, maxDepth: Double) -> [DepthSample] {
        let totalSeconds = 90
        var samples: [DepthSample] = []
        samples.reserveCapacity(totalSeconds + 1)
        for second in 0...totalSeconds {
            let t = Double(second) / Double(totalSeconds) // 0…1
            // Symmetric sine bump: 0 at ends, 1 at the middle → smooth V.
            let shape = sin(t * .pi)
            let depth = (maxDepth * shape * 100).rounded() / 100 // 2-dp, tidy
            samples.append(
                DepthSample(
                    timestamp: start.addingTimeInterval(Double(second)),
                    depthMeters: depth
                )
            )
        }
        return samples
    }

    /// A short surface GPS track around the spot: a few points drifting slightly
    /// from the spot center, deterministic.
    private static func surfaceTrack(start: Date, end: Date, fixture: SpotFixture) -> [TrackPoint] {
        let count = 6
        let span = end.timeIntervalSince(start)
        var points: [TrackPoint] = []
        points.reserveCapacity(count)
        for index in 0..<count {
            let fraction = count > 1 ? Double(index) / Double(count - 1) : 0
            // Small deterministic drift (~30–60 m) so the path is visible.
            let latDrift = 0.0003 * sin(fraction * .pi * 2)
            let lonDrift = 0.0003 * fraction
            points.append(
                TrackPoint(
                    // Fixed UUIDs would need a generator; a stable derived id keeps
                    // determinism where it matters (the coordinates + timestamps).
                    timestamp: start.addingTimeInterval(span * fraction),
                    location: GeoPoint(
                        latitude: fixture.latitude + latDrift,
                        longitude: fixture.longitude + lonDrift,
                        horizontalAccuracy: 5
                    )
                )
            )
        }
        return points
    }

    /// A handful of heart-rate samples spread across the session, plausible for a
    /// relaxed freedive (60–110 bpm), deterministic.
    private static func heartRateSamples(start: Date, end: Date) -> [HeartRateSample] {
        let count = 8
        let span = end.timeIntervalSince(start)
        var samples: [HeartRateSample] = []
        samples.reserveCapacity(count)
        let bpms: [Double] = [72, 68, 64, 88, 96, 70, 66, 74]
        for index in 0..<count {
            let fraction = count > 1 ? Double(index) / Double(count - 1) : 0
            samples.append(
                HeartRateSample(
                    timestamp: start.addingTimeInterval(span * fraction),
                    bpm: bpms[index % bpms.count]
                )
            )
        }
        return samples
    }
}
#endif
