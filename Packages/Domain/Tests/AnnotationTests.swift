import Foundation
import Testing
@testable import Domain

@Suite("DiveSession.annotation")
struct AnnotationTests {
    @Test("annotation fields default to empty and round-trip through JSON")
    func roundTrip() throws {
        var session = DiveSession(startTime: Date(timeIntervalSince1970: 0))
        #expect(session.title == nil)
        #expect(session.notes == nil)
        #expect(session.rating == nil)
        #expect(session.locationNameEdited == false)

        session.title = "Blue Hole"
        session.notes = "great viz"
        session.rating = 5
        session.locationName = "Dahab"
        session.locationNameEdited = true

        let decoded = try JSONDecoder().decode(DiveSession.self, from: JSONEncoder().encode(session))
        #expect(decoded.title == "Blue Hole")
        #expect(decoded.notes == "great viz")
        #expect(decoded.rating == 5)
        #expect(decoded.locationName == "Dahab")
        #expect(decoded.locationNameEdited == true)
    }

    @Test("a payload predating annotation decodes with safe defaults")
    func legacyDecode() throws {
        let json = """
        {"id":"\(UUID().uuidString)","startTime":0,"dives":[],"markers":[]}
        """
        let session = try JSONDecoder().decode(DiveSession.self, from: Data(json.utf8))
        #expect(session.title == nil)
        #expect(session.notes == nil)
        #expect(session.rating == nil)
        #expect(session.locationNameEdited == false)
    }
}
