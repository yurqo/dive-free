import Foundation

/// Pure, deterministic UDDF 3.2.0 serializer for a `DiveSession`.
///
/// UDDF 3.2.0 element structure targeted (nesting + ordering per the UDDF 3.2.0
/// schema, verified importable by Subsurface):
///
/// ```
/// <uddf version="3.2.0">
///   <generator>
///     <name>DiveFree</name>
///     <type>logbook</type>
///     <datetime>…</datetime>
///   </generator>
///   <diver> … </diver>                         (optional; owner block)
///   <divesite>                                  (optional; when we have a location)
///     <site id="…"><name>…</name>
///       <geography><latitude/><longitude/></geography>
///     </site>
///   </divesite>
///   <profiledata>
///     <repetitiongroup id="…">
///       <dive id="…">
///         <informationbeforedive>
///           <divenumber>…</divenumber>
///           <datetime>…</datetime>              (UTC ISO-8601)
///           <apnoe>1</apnoe>                     (freedive marker)
///         </informationbeforedive>
///         <samples>
///           <waypoint>
///             <depth>metres</depth>
///             <divetime>seconds-from-dive-start</divetime>
///             <temperature>kelvin</temperature> (optional)
///           </waypoint> …
///         </samples>
///         <informationafterdive>
///           <greatestdepth>metres</greatestdepth>
///           <diveduration>seconds</diveduration>
///         </informationafterdive>
///       </dive> …
///     </repetitiongroup>
///   </profiledata>
/// </uddf>
/// ```
///
/// Notes:
/// - UDDF temperatures are in **kelvin**; water-temperature samples (°C) are
///   converted (`K = °C + 273.15`) and folded into the nearest waypoint.
/// - All datetimes are UTC ISO-8601 and numerics are C-locale, so output is
///   byte-stable.
public enum UDDFExport {
    /// Max time gap (seconds) for a temperature sample to attach to a waypoint.
    private static let temperatureWindow: TimeInterval = 5.0

    public static func export(_ session: DiveSession) -> String {
        var lines: [String] = []
        lines.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        lines.append("<uddf version=\"3.2.0\">")

        // Generator.
        lines.append("  <generator>")
        lines.append("    <name>DiveFree</name>")
        lines.append("    <type>logbook</type>")
        lines.append("    <datetime>\(ExportFormatting.isoString(session.startTime))</datetime>")
        lines.append("  </generator>")

        // Dive site, when we have coordinates.
        if let location = session.location {
            let siteName = (session.locationName?.isEmpty == false ? session.locationName! : "Dive site")
            lines.append("  <divesite>")
            lines.append("    <site id=\"site-\(session.id.uuidString)\">")
            lines.append("      <name>\(ExportFormatting.xmlEscaped(siteName))</name>")
            lines.append("      <geography>")
            lines.append("        <latitude>\(ExportFormatting.coordinate(location.latitude))</latitude>")
            lines.append("        <longitude>\(ExportFormatting.coordinate(location.longitude))</longitude>")
            lines.append("      </geography>")
            lines.append("    </site>")
            lines.append("  </divesite>")
        }

        // Profile data.
        lines.append("  <profiledata>")
        lines.append("    <repetitiongroup id=\"rg-\(session.id.uuidString)\">")

        let temps = session.temperatureSamples.sorted { $0.timestamp < $1.timestamp }

        for (index, dive) in session.dives.sorted(by: { $0.startTime < $1.startTime }).enumerated() {
            lines.append("      <dive id=\"dive-\(dive.id.uuidString)\">")
            lines.append("        <informationbeforedive>")
            lines.append("          <divenumber>\(index + 1)</divenumber>")
            lines.append("          <datetime>\(ExportFormatting.isoString(dive.startTime))</datetime>")
            // Freediving / breath-hold flag.
            lines.append("          <apnoe>1</apnoe>")
            lines.append("        </informationbeforedive>")

            lines.append("        <samples>")
            for sample in dive.samples.sorted(by: { $0.timestamp < $1.timestamp }) {
                let divetime = sample.timestamp.timeIntervalSince(dive.startTime)
                lines.append("          <waypoint>")
                lines.append("            <depth>\(ExportFormatting.meters(sample.depthMeters))</depth>")
                lines.append("            <divetime>\(ExportFormatting.number(divetime, fractionDigits: 0))</divetime>")
                if let celsius = nearestTemperature(in: temps, at: sample.timestamp) {
                    let kelvin = celsius + 273.15
                    lines.append("            <temperature>\(ExportFormatting.number(kelvin, fractionDigits: 2))</temperature>")
                }
                lines.append("          </waypoint>")
            }
            lines.append("        </samples>")

            lines.append("        <informationafterdive>")
            lines.append("          <greatestdepth>\(ExportFormatting.meters(dive.maxDepthMeters))</greatestdepth>")
            lines.append("          <diveduration>\(ExportFormatting.number(dive.duration, fractionDigits: 0))</diveduration>")
            lines.append("        </informationafterdive>")

            lines.append("      </dive>")
        }

        lines.append("    </repetitiongroup>")
        lines.append("  </profiledata>")
        lines.append("</uddf>")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Water temperature (°C) nearest `time` within `temperatureWindow`, else nil.
    private static func nearestTemperature(in samples: [TemperatureSample], at time: Date) -> Double? {
        var best: (delta: TimeInterval, celsius: Double)?
        for sample in samples {
            let delta = abs(sample.timestamp.timeIntervalSince(time))
            if delta <= temperatureWindow, best == nil || delta < best!.delta {
                best = (delta, sample.celsius)
            }
        }
        return best?.celsius
    }
}
