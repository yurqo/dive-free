import Foundation

/// Shared, deterministic formatting helpers for the pure Domain export
/// serializers (`GPXExport`, `CSVExport`, `UDDFExport`, `TCXExport`).
///
/// Everything here is fixed to UTC / ISO-8601 with the C locale so exported
/// documents are byte-for-byte stable across runs and locales — which is what
/// makes the golden-file style tests reproducible.
enum ExportFormatting {
    /// XML-escapes text destined for element/attribute content. Escapes the five
    /// predefined XML entities. Safe to apply to any interpolated user text
    /// (titles, notes, marker labels, location names).
    static func xmlEscaped(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(character)
            }
        }
        return out
    }

    /// Formats a `Date` as a deterministic ISO-8601 string in UTC with a
    /// trailing `Z` (e.g. `2026-07-24T12:34:56Z`). No fractional seconds, so
    /// output is stable across runs and locales.
    ///
    /// A fresh `ISO8601DateFormatter` is built per call rather than sharing a
    /// static instance: `ISO8601DateFormatter` is not `Sendable` and would trip
    /// Swift 6 strict-concurrency checks as a stored static. Formatters are
    /// cheap enough for the export path, and a per-call instance is inherently
    /// thread-safe with no shared mutable state.
    static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Formats a `Double` with a fixed number of fraction digits using the C
    /// locale (always `.` as the decimal separator), so coordinates and depths
    /// never vary by the host locale. Trailing precision is fixed, not trimmed,
    /// to keep golden output stable.
    static func number(_ value: Double, fractionDigits: Int) -> String {
        String(format: "%.\(fractionDigits)f", value)
    }

    /// A latitude/longitude coordinate to 7 decimal places (~1cm), C locale.
    static func coordinate(_ value: Double) -> String { number(value, fractionDigits: 7) }

    /// A depth / altitude / distance in meters to 2 decimal places, C locale.
    static func meters(_ value: Double) -> String { number(value, fractionDigits: 2) }
}
