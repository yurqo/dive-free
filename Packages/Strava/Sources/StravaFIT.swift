import Foundation
import Domain

/// Strava's FIT exporter. The encoder itself lives in `Domain` (`FITExport`) so
/// FIT is a first-class exporter alongside GPX/CSV/UDDF/TCX; this thin façade
/// keeps the Strava upload path's existing symbol while delegating to it,
/// producing byte-identical output.
///
/// FIT is the format Strava's `/uploads` endpoint gets for a session with a
/// position + time-series data, because it carries **both** `total_calories`
/// (which GPX can't) and a per-point temperature stream (which TCX can't).
public enum StravaFIT {
    /// Builds a FIT activity file for `session`, or `nil` when it has no position
    /// source or no time-series data. Delegates to `Domain.FITExport`.
    public static func build(_ session: DiveSession) -> Data? {
        FITExport.build(session)
    }
}
