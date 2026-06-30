import Testing
import Foundation
@testable import Domain

@Suite("suggestTrips")
struct TripSuggestionTests {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func input(_ y: Int, _ m: Int, _ d: Int, _ loc: GeoPoint? = nil) -> TripSuggestionInput {
        TripSuggestionInput(id: UUID(), startTime: day(y, m, d), location: loc)
    }

    @Test("sessions within the gap and area form one trip")
    func oneTrip() {
        let bali = GeoPoint(latitude: -8.34, longitude: 115.5)
        let groups = suggestTrips(from: [input(2026, 6, 1, bali), input(2026, 6, 2, bali), input(2026, 6, 3, bali)])
        #expect(groups.count == 1)
        #expect(groups.first?.count == 3)
    }

    @Test("a gap longer than 3 days splits trips")
    func timeGap() {
        let groups = suggestTrips(from: [input(2026, 6, 1), input(2026, 6, 10)])
        #expect(groups.count == 2)
    }

    @Test("a far location jump splits trips even within the time window")
    func locationJump() {
        let bali = GeoPoint(latitude: -8.34, longitude: 115.5)
        let egypt = GeoPoint(latitude: 27.9, longitude: 34.3)
        let groups = suggestTrips(from: [input(2026, 6, 1, bali), input(2026, 6, 2, egypt)])
        #expect(groups.count == 2)
    }

    @Test("no-GPS sessions chain by time only")
    func noGPS() {
        let groups = suggestTrips(from: [input(2026, 6, 1, nil), input(2026, 6, 2, nil)])
        #expect(groups.count == 1)
    }

    @Test("empty input yields no trips")
    func empty() {
        #expect(suggestTrips(from: []).isEmpty)
    }
}
