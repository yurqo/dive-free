import Foundation

/// Greedy proximity clustering of geographic points, used to collapse nearby map
/// annotations into a single cluster when the map is zoomed out.
public enum GeoClustering {
    /// Groups `points` into clusters by angular proximity, returning groups of
    /// indices into the original array (order preserved by first occurrence).
    ///
    /// A point joins the first existing cluster whose seed is within
    /// `thresholdDegrees` (Euclidean distance in lat/lon degrees — adequate for
    /// the small extent of a single dive site). With `thresholdDegrees <= 0`
    /// every point is its own cluster.
    public static func cluster(_ points: [GeoPoint], thresholdDegrees: Double) -> [[Int]] {
        var groups: [[Int]] = []
        var seeds: [GeoPoint] = []
        for (index, point) in points.enumerated() {
            if thresholdDegrees > 0,
               let groupIndex = seeds.firstIndex(where: { distance($0, point) <= thresholdDegrees }) {
                groups[groupIndex].append(index)
            } else {
                groups.append([index])
                seeds.append(point)
            }
        }
        return groups
    }

    private static func distance(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let dLat = a.latitude - b.latitude
        let dLon = a.longitude - b.longitude
        return (dLat * dLat + dLon * dLon).squareRoot()
    }
}
