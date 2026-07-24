import SwiftUI
import UIKit
import Domain

/// A single-session export format. Wraps the pure Domain serializers with the
/// UI-side concerns: a display name, a file extension, byte production, and a
/// temp-file writer for handing off to the system share sheet.
enum ExportFormat: String, CaseIterable, Identifiable {
    case fit, uddf, gpx, csv, tcx

    var id: String { rawValue }

    /// Friendly, localizable label naming the format and its typical consumer.
    var displayName: LocalizedStringKey {
        switch self {
        case .fit:  "FIT (Garmin/Strava)"
        case .uddf: "UDDF (dive log)"
        case .gpx:  "GPX (map track)"
        case .csv:  "CSV (spreadsheet)"
        case .tcx:  "TCX (fitness)"
        }
    }

    var fileExtension: String {
        switch self {
        case .fit:  "fit"
        case .uddf: "uddf"
        case .gpx:  "gpx"
        case .csv:  "csv"
        case .tcx:  "tcx"
        }
    }

    /// The serialized bytes for `session`, or `nil` when the format can't be
    /// produced (only FIT: it needs a position source and time-series data).
    func fileData(for session: DiveSession) -> Data? {
        switch self {
        case .fit:  FITExport.build(session)
        case .uddf: UDDFExport.export(session).data(using: .utf8)
        case .gpx:  GPXExport.export(session).data(using: .utf8)
        case .csv:  CSVExport.export(session).data(using: .utf8)
        case .tcx:  TCXExport.export(session).data(using: .utf8)
        }
    }

    /// Writes `session`'s export to a temp file named
    /// `DiveFree <yyyy-MM-dd HHmm>.<ext>` and returns its URL, or `nil` when the
    /// format can't be produced. Throws only on a filesystem write failure.
    ///
    /// Each export goes into its own unique temp subdirectory so the readable
    /// filename can't collide: two sessions started the same minute (minute-
    /// resolution stamp) — or a re-export while an earlier share is still in
    /// flight — would otherwise clobber each other under `.atomic`.
    func writeTempFile(for session: DiveSession) throws -> URL? {
        guard let data = fileData(for: session) else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(Self.fileName(for: session, ext: fileExtension))
        try data.write(to: url, options: .atomic)
        return url
    }

    /// A sanitized, human-readable base filename for a session export.
    private static func fileName(for session: DiveSession, ext: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let stamp = formatter.string(from: session.startTime)
        let base = "DiveFree \(stamp)"
        return "\(sanitize(base)).\(ext)"
    }

    /// Strips characters that are illegal or awkward in filenames.
    private static func sanitize(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = name.components(separatedBy: illegal).joined(separator: "-")
        return cleaned.isEmpty ? "DiveFree" : cleaned
    }
}

/// Minimal wrapper around `UIActivityViewController` for sharing arbitrary items
/// (exported files, backups) via the system share sheet.
struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: applicationActivities
        )
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
