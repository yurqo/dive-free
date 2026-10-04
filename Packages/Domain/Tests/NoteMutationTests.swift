import Foundation
import Testing
@testable import Domain

struct NoteMutationTests {
    @Test func testFieldMergeIsIndependentOfDeliveryOrder() {
        let session = UUID(), marker = UUID(), date = Date()
        let a = NoteMutation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, sessionID: session, markerID: marker, date: date, changes: ["title": "First", "text": "Body"])
        let b = NoteMutation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, sessionID: session, markerID: marker, date: date, changes: ["title": "Second"])
        #expect(NoteMutation.merged([a,b]) == NoteMutation.merged([b,a,a]))
        #expect(NoteMutation.merged([b,a])["title"] == "Second")
        #expect(NoteMutation.merged([b,a])["text"] == "Body")
    }
}
