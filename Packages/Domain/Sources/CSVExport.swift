import Foundation

/// Pure, deterministic RFC-4180 CSV serializer for a `DiveSession`.
///
/// Emits a header row followed by **one row per dive** (dives sorted by start
/// time). Fields containing a comma, double-quote, or newline are quoted and
/// embedded quotes are doubled, per RFC 4180. Rows end with CRLF (`\r\n`), also
/// per RFC 4180. Numbers use the C locale (`.` decimal separator) and times are
/// UTC ISO-8601, so output is byte-stable.
///
/// Column order (documented so importers/tests can rely on it):
///  1. session_id            — session UUID
///  2. session_start         — session start, UTC ISO-8601
///  3. session_end           — session end, UTC ISO-8601 (empty if in progress)
///  4. dive_number           — 1-based index within the session
///  5. dive_start_offset_s   — seconds from session start to this dive's start
///  6. dive_duration_s       — dive duration in seconds
///  7. max_depth_m           — dive max depth in meters
///  8. location_name         — session location name (may be empty)
///  9. rating                — session rating 1–5 (empty if unrated)
/// 10. notes                 — session free-text notes (may be empty)
public enum CSVExport {
    private static let header = [
        "session_id",
        "session_start",
        "session_end",
        "dive_number",
        "dive_start_offset_s",
        "dive_duration_s",
        "max_depth_m",
        "location_name",
        "rating",
        "notes",
    ]

    public static func export(_ session: DiveSession) -> String {
        var rows: [String] = [row(header)]

        let sessionId = session.id.uuidString
        let sessionStart = ExportFormatting.isoString(session.startTime)
        let sessionEnd = session.endTime.map(ExportFormatting.isoString) ?? ""
        let locationName = session.locationName ?? ""
        let rating = session.rating.map(String.init) ?? ""
        let notes = session.notes ?? ""

        for (index, dive) in session.dives.sorted(by: { $0.startTime < $1.startTime }).enumerated() {
            let offset = dive.startTime.timeIntervalSince(session.startTime)
            rows.append(row([
                sessionId,
                sessionStart,
                sessionEnd,
                String(index + 1),
                ExportFormatting.number(offset, fractionDigits: 0),
                ExportFormatting.number(dive.duration, fractionDigits: 0),
                ExportFormatting.meters(dive.maxDepthMeters),
                // Free-text columns pass through the formula-injection guard;
                // numeric columns above are machine-formatted and safe as-is.
                defuseFormula(locationName),
                rating,
                defuseFormula(notes),
            ]))
        }

        // RFC-4180: records separated by CRLF, and a trailing CRLF is permitted.
        return rows.joined(separator: "\r\n") + "\r\n"
    }

    /// Joins fields into one RFC-4180 record, quoting where required.
    private static func row(_ fields: [String]) -> String {
        fields.map(escape).joined(separator: ",")
    }

    /// Neutralizes spreadsheet formula injection: a free-text field beginning with
    /// `=`, `+`, `-`, `@`, a tab, or a CR is treated as a formula by Excel/Sheets,
    /// so prefix a single apostrophe (the standard, least-surprising mitigation)
    /// to force it to render as literal text. Applied before RFC-4180 quoting, and
    /// only to free-text columns (never machine-formatted numerics).
    private static func defuseFormula(_ field: String) -> String {
        guard let first = field.first,
              first == "=" || first == "+" || first == "-" || first == "@"
                || first == "\t" || first == "\r"
        else { return field }
        return "'" + field
    }

    /// RFC-4180 quoting: wrap in quotes and double any embedded quotes when the
    /// field contains a comma, quote, CR, or LF.
    private static func escape(_ field: String) -> String {
        let needsQuoting = field.contains(",")
            || field.contains("\"")
            || field.contains("\n")
            || field.contains("\r")
        guard needsQuoting else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
