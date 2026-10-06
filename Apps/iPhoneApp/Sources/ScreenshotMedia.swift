#if DEBUG
import Foundation
import SwiftData
import Persistence

/// Marketing-only media. Runs exclusively against the throwaway screenshot store;
/// never imports anything into the user's Photos library or private iCloud store.
@MainActor
enum ScreenshotMedia {
    static func seed(into context: ModelContext) {
        guard let session = DemoData.featuredSession(in: context) else {
            fatalError("Screenshot store has no featured session")
        }
        session.title = String(localized: "Reef encounters")
        for index in 1...4 {
            guard let url = Bundle.main.url(forResource: "Jemeluk-\(index)", withExtension: "jpg"),
                  let data = try? Data(contentsOf: url) else {
                fatalError("Missing Jemeluk screenshot photo \(index)")
            }
            context.insert(PhotoRecord(
                thumbnailData: data,
                createdAt: session.startTime.addingTimeInterval(Double(index)),
                session: session
            ))
        }
        do { try context.save() } catch { fatalError("Cannot save screenshot media: \(error)") }
    }
}
#endif
