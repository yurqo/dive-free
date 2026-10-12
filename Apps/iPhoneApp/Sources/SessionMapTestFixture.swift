#if DEBUG
import Foundation
import Domain

/// Synthetic fixtures for map interaction tests. Separate from marketing captures.
enum SessionMapTestFixture {
    static func session() -> DiveSession {
        if let json = ProcessInfo.processInfo.environment["DIVEFREE_MAP_PREVIEW_JSON"],
           let data = json.data(using: .utf8), let archive = try? BackupArchive.decode(data),
           let session = archive.sessions.first {
            return session
        }
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--screenshot-map-backup"), arguments.indices.contains(index + 1),
           let data = try? Data(contentsOf: URL(fileURLWithPath: arguments[index + 1])),
           let archive = try? BackupArchive.decode(data), let session = archive.sessions.first {
            return session
        }
        let index = arguments.firstIndex(of: "--screenshot-map-case")
        let scenario = index.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? "pair"
        let start = Date(timeIntervalSince1970: 1_781_078_400)
        let centre = GeoPoint(latitude: -8.33814, longitude: 115.66030, horizontalAccuracy: 3)
        let west = GeoPoint(latitude: centre.latitude - 0.002, longitude: centre.longitude - 0.002)
        let east = GeoPoint(latitude: centre.latitude + 0.002, longitude: centre.longitude + 0.002)
        func track(_ seconds: Double, _ geo: GeoPoint) -> TrackPoint {
            TrackPoint(timestamp: start.addingTimeInterval(seconds), location: geo)
        }
        func dive(_ index: Int, _ seconds: Double) -> Dive {
            let time = start.addingTimeInterval(seconds)
            return Dive(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!,
                        startTime: time, endTime: time.addingTimeInterval(20), maxDepthMeters: 4,
                        samples: [DepthSample(timestamp: time, depthMeters: 0),
                                  DepthSample(timestamp: time.addingTimeInterval(10), depthMeters: 4),
                                  DepthSample(timestamp: time.addingTimeInterval(20), depthMeters: 0)])
        }
        let dives: [Dive]
        let path: [TrackPoint]
        switch scenario {
        case "mixed":
            dives = [dive(1, 10), dive(2, 50)]
            path = [track(0, west), track(10, west), track(30, centre), track(50, centre), track(70, east), track(80, east)]
        case "wide":
            dives = [dive(1, 10)]
            path = [track(0, west), track(10, west), track(30, east), track(40, east)]
        case "dense":
            dives = (1...12).map { dive($0, Double($0) * 40) }
            path = [track(0, centre), track(600, centre)]
        default:
            dives = [dive(1, 10)]
            path = [track(0, centre), track(60, centre)]
        }
        return DiveSession(startTime: start, endTime: path.last!.timestamp, dives: dives,
                           location: centre, track: path, smoothTrack: false)
    }
}
#endif
