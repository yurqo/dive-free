import Foundation
import Testing
@testable import Domain

@Suite("DiveConditions")
struct DiveConditionsTests {
    @Test("empty by default; any set field makes it non-empty")
    func emptiness() {
        #expect(DiveConditions().isEmpty)
        #expect(!DiveConditions(visibility: .good).isEmpty)
        #expect(!DiveConditions(waterTemperatureCelsius: 18).isEmpty)
    }

    @Test("round-trips through JSON")
    func roundTrip() throws {
        let conditions = DiveConditions(
            visibility: .excellent, current: .light, surface: .calm,
            tide: .high, waterTemperatureCelsius: 24, airTemperatureCelsius: 29
        )
        let decoded = try JSONDecoder().decode(DiveConditions.self, from: JSONEncoder().encode(conditions))
        #expect(decoded == conditions)
    }

    @Test("session conditions default empty; a legacy payload decodes empty")
    func sessionDefaults() throws {
        #expect(DiveSession(startTime: Date(timeIntervalSince1970: 0)).conditions.isEmpty)
        let json = """
        {"id":"\(UUID().uuidString)","startTime":0,"dives":[],"markers":[]}
        """
        let session = try JSONDecoder().decode(DiveSession.self, from: Data(json.utf8))
        #expect(session.conditions.isEmpty)
    }
}
