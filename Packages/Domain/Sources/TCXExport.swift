import Foundation

/// Pure, deterministic Garmin Training Center Database (TCX) v2 serializer for a
/// `DiveSession`.
///
/// Structure:
/// ```
/// <TrainingCenterDatabase>
///   <Activities>
///     <Activity Sport="Other">
///       <Id>ISO8601 session start</Id>
///       <Lap StartTime="ISO8601 dive start">        (one per dive)
///         <TotalTimeSeconds>…</TotalTimeSeconds>
///         <DistanceMeters>0</DistanceMeters>
///         <Calories>…</Calories>                    (active energy, first lap only)
///         <Intensity>Active</Intensity>
///         <TriggerMethod>Manual</TriggerMethod>
///         <Track>
///           <Trackpoint>                            (one per depth sample)
///             <Time>…</Time>
///             <Position>                            (when a surface fix exists)
///               <LatitudeDegrees/><LongitudeDegrees/>
///             </Position>
///             <AltitudeMeters>-depth</AltitudeMeters>
///             <HeartRateBpm><Value/></HeartRateBpm> (when a HR sample is near)
///           </Trackpoint> …
///         </Track>
///       </Lap> …
///     </Activity>
///   </Activities>
/// </TrainingCenterDatabase>
/// ```
///
/// The per-dive depth samples form the trackpoint spine; depth (positive down)
/// is written as a negative `<AltitudeMeters>` (below the surface). Surface
/// position at each trackpoint is interpolated over the session's cleaned track,
/// computed once via `DiveSession.surfacePosition(in:at:)`.
/// All datetimes are UTC ISO-8601 and numerics C-locale, so output is stable.
public enum TCXExport {
    /// Max time gap (seconds) for a HR sample to attach to a trackpoint.
    private static let heartRateWindow: TimeInterval = 5.0

    public static func export(_ session: DiveSession) -> String {
        var lines: [String] = []
        lines.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        lines.append(
            "<TrainingCenterDatabase "
            + "xmlns=\"http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2\" "
            + "xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" "
            + "xsi:schemaLocation=\"http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2 "
            + "http://www.garmin.com/xmlschemas/TrainingCenterDatabasev2.xsd\">"
        )
        lines.append("  <Activities>")
        lines.append("    <Activity Sport=\"Other\">")
        lines.append("      <Id>\(ExportFormatting.isoString(session.startTime))</Id>")

        let hr = session.heartRateSamples.sorted { $0.timestamp < $1.timestamp }
        // Clean the surface track once; every trackpoint interpolates against it,
        // so recomputing it per sample would re-run the Kalman smoother O(samples).
        let track = session.effectiveTrack

        for (index, dive) in session.dives.sorted(by: { $0.startTime < $1.startTime }).enumerated() {
            lines.append("      <Lap StartTime=\"\(ExportFormatting.isoString(dive.startTime))\">")
            // A duration in seconds, not a distance — format it as a plain number
            // rather than coupling to the meters precision.
            lines.append("        <TotalTimeSeconds>\(ExportFormatting.number(dive.duration, fractionDigits: 1))</TotalTimeSeconds>")
            lines.append("        <DistanceMeters>0</DistanceMeters>")
            // Calories are session-wide; attribute them to the first lap only.
            if index == 0, let kcal = session.activeEnergyKilocalories {
                lines.append("        <Calories>\(Int(kcal.rounded()))</Calories>")
            }
            lines.append("        <Intensity>Active</Intensity>")
            lines.append("        <TriggerMethod>Manual</TriggerMethod>")
            lines.append("        <Track>")
            for sample in dive.samples.sorted(by: { $0.timestamp < $1.timestamp }) {
                lines.append("          <Trackpoint>")
                lines.append("            <Time>\(ExportFormatting.isoString(sample.timestamp))</Time>")
                if let position = DiveSession.surfacePosition(in: track, at: sample.timestamp) {
                    lines.append("            <Position>")
                    lines.append("              <LatitudeDegrees>\(ExportFormatting.coordinate(position.latitude))</LatitudeDegrees>")
                    lines.append("              <LongitudeDegrees>\(ExportFormatting.coordinate(position.longitude))</LongitudeDegrees>")
                    lines.append("            </Position>")
                }
                // Depth below the surface → negative altitude.
                lines.append("            <AltitudeMeters>\(ExportFormatting.meters(-sample.depthMeters))</AltitudeMeters>")
                if let bpm = nearestHeartRate(in: hr, at: sample.timestamp) {
                    lines.append("            <HeartRateBpm>")
                    lines.append("              <Value>\(Int(bpm.rounded()))</Value>")
                    lines.append("            </HeartRateBpm>")
                }
                lines.append("          </Trackpoint>")
            }
            lines.append("        </Track>")
            lines.append("      </Lap>")
        }

        lines.append("    </Activity>")
        lines.append("  </Activities>")
        lines.append("</TrainingCenterDatabase>")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Heart rate (bpm) nearest `time` within `heartRateWindow`, else nil.
    private static func nearestHeartRate(in samples: [HeartRateSample], at time: Date) -> Double? {
        var best: (delta: TimeInterval, bpm: Double)?
        for sample in samples {
            let delta = abs(sample.timestamp.timeIntervalSince(time))
            if delta <= heartRateWindow, best == nil || delta < best!.delta {
                best = (delta, sample.bpm)
            }
        }
        return best?.bpm
    }
}
