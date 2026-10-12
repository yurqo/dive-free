import Foundation
import CoreGraphics
import Domain

/// Presentation geometry only. Expanding labels never changes recorded positions.
struct SessionMapPoint: Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        case submersion(diveID: UUID, number: Int)
        case surfacing(diveID: UUID, number: Int)
        case marker(emoji: String, label: String)
    }

    let id: String
    let geo: GeoPoint
    let timestamp: Date
    let kind: Kind
}

struct SessionMapCluster: Identifiable {
    enum Presentation: Equatable {
        case point
        case divePair(number: Int)
        case count(Int)
    }

    let members: [SessionMapPoint]
    var id: String { members.map(\.id).sorted().joined(separator: "+") }

    var presentation: Presentation {
        guard members.count > 1 else { return .point }
        // Only a matching start/end pair represents one dive. Mixed pairs,
        // notes, and groups of 3+ retain their actual *point* count.
        if members.count == 2 {
            switch (members[0].kind, members[1].kind) {
            case let (.submersion(a, number), .surfacing(b, other)),
                 let (.surfacing(a, number), .submersion(b, other)):
                if a == b, number == other { return .divePair(number: number) }
            default: break
            }
        }
        return .count(members.count)
    }

    var geo: GeoPoint {
        let count = Double(members.count)
        let latitude = members.map(\.geo.latitude).reduce(0, +) / count
        // A cluster beside the date line must not move to longitude zero.
        let sinSum = members.reduce(0.0) { $0 + sin($1.geo.longitude * .pi / 180) }
        let cosSum = members.reduce(0.0) { $0 + cos($1.geo.longitude * .pi / 180) }
        return GeoPoint(latitude: latitude, longitude: atan2(sinSum, cosSum) * 180 / .pi)
    }
}

enum SessionMapLayout {
    static let minimumSeparation: CGFloat = 52
    static let expandedSpacing: CGFloat = 56

    /// Cluster projected screen positions, so zoom, rotation, latitude and
    /// iPhone/iPad size all use the same touch-target separation.
    static func clusters(
        points: [SessionMapPoint], projected: [String: CGPoint], fallbackLatitudeSpan: Double
    ) -> [SessionMapCluster] {
        let groups: [[Int]]
        if points.allSatisfy({ projected[$0.id] != nil }) {
            var remaining = Set(points.indices)
            var components: [[Int]] = []
            while let seed = remaining.min() {
                remaining.remove(seed)
                var component = [seed]
                var cursor = 0
                while cursor < component.count {
                    let position = projected[points[component[cursor]].id]!
                    let neighbours = remaining.sorted().filter { index in
                        let other = projected[points[index].id]!
                        return hypot(position.x - other.x, position.y - other.y) < minimumSeparation
                    }
                    for index in neighbours { remaining.remove(index) }
                    component.append(contentsOf: neighbours)
                    cursor += 1
                }
                components.append(component)
            }
            groups = components
        } else {
            // The first MapKit camera callback supplies the projection. Keep a
            // geographic fallback until then; no point is omitted.
            groups = GeoClustering.cluster(points.map(\.geo), thresholdDegrees: fallbackLatitudeSpan * 0.05)
        }
        return groups.map { indices in
            SessionMapCluster(members: indices.map { points[$0] }.sorted {
                $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp
            })
        }
    }

    /// A bounded fan/grid with 44pt targets. Very large clusters also expose
    /// every member in a scrolling list; selecting a row brings it into the fan.
    static func expandedPositions(
        ids: [String], centre: CGPoint, bounds: CGRect, selectedID: String?
    ) -> [String: CGPoint] {
        guard !ids.isEmpty, bounds.width >= 44, bounds.height >= 44 else { return [:] }
        let columns = min(ids.count, max(1, min(4, Int(bounds.width / expandedSpacing))))
        let rows = max(1, Int(bounds.height / expandedSpacing))
        let capacity = min(16, columns * rows)
        var visible = Array(ids.prefix(capacity))
        if let selectedID, ids.contains(selectedID), !visible.contains(selectedID) {
            visible[visible.count - 1] = selectedID
        }
        let actualRows = Int(ceil(Double(visible.count) / Double(columns)))
        let width = CGFloat(columns - 1) * expandedSpacing
        let height = CGFloat(actualRows - 1) * expandedSpacing
        let left = min(max(centre.x - width / 2, bounds.minX + 22), bounds.maxX - 22 - width)
        let top = min(max(centre.y - height / 2, bounds.minY + 22), bounds.maxY - 22 - height)
        return Dictionary(uniqueKeysWithValues: visible.enumerated().map { index, id in
            (id, CGPoint(x: left + CGFloat(index % columns) * expandedSpacing,
                         y: top + CGFloat(index / columns) * expandedSpacing))
        })
    }
}
