import Foundation
import CoreLocation
import Testing
@testable import Sensors

struct LocationProviderTests {
    private func fix(time: Date, accuracy: Double = 5) -> CLLocation {
        CLLocation(coordinate: .init(latitude: 1.3, longitude: 103.8), altitude: 0,
                   horizontalAccuracy: accuracy, verticalAccuracy: 5, timestamp: time)
    }

    @Test func preservesGPSMeasurementTimeRatherThanBatchDeliveryTime() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let measured = now.addingTimeInterval(-10)
        let point = try #require(timestampedLocation(fix(time: measured), now: now))
        #expect(point.timestamp == measured)
        #expect(point.location.horizontalAccuracy == 5)
    }

    @Test func rejectsStaleInvalidAndFutureFixes() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(timestampedLocation(fix(time: now.addingTimeInterval(-60)), now: now) == nil)
        #expect(timestampedLocation(fix(time: now.addingTimeInterval(60)), now: now) == nil)
        #expect(timestampedLocation(fix(time: now, accuracy: -1), now: now) == nil)
        #expect(timestampedLocation(fix(time: now, accuracy: .nan), now: now) == nil)
    }
}
