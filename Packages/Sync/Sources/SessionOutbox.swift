import Foundation

/// Durable copies of outgoing sessions, retained until the phone confirms a save.
/// Transfer snapshots are separate files: refreshing a pending session must never
/// modify a source file WatchConnectivity is still reading.
final class SessionOutbox {
    struct Entry: Codable {
        let id: String
        let sessionID: UUID
        var data: Data
        var isResync: Bool
    }

    private let directory: URL
    private var snapshotsDirectory: URL { directory.appendingPathComponent("Transfers", isDirectory: true) }

    init(directory: URL) { self.directory = directory }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SessionOutbox", isDirectory: true)
    }

    func save(_ entry: Entry) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(entry).write(to: entryURL(entry.id), options: .atomic)
    }

    func load(onError: (Error) -> Void) -> [Entry] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        do {
            return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "plist" }
                .compactMap { url in
                    do {
                        let entry = try PropertyListDecoder().decode(Entry.self, from: Data(contentsOf: url))
                        // An untrusted transfer id must never become a filesystem path.
                        guard try entryURL(entry.id) == url else { throw CocoaError(.fileReadCorruptFile) }
                        return entry
                    } catch { onError(error); return nil }
                }
        } catch { onError(error); return [] }
    }

    func remove(_ id: String) throws {
        let url = try entryURL(id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    func makeSnapshot(id: String, data: Data) throws -> URL {
        _ = try entryURL(id)
        try FileManager.default.createDirectory(at: snapshotsDirectory, withIntermediateDirectories: true)
        let url = snapshotsDirectory.appendingPathComponent("\(id)-\(UUID().uuidString).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    func removeSnapshot(_ url: URL) {
        guard url.deletingLastPathComponent().standardizedFileURL == snapshotsDirectory.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func removeUnusedSnapshots(keeping urls: Set<URL>) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: snapshotsDirectory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        // Avoid racing a newly enqueued snapshot that isn't in the caller's WC
        // queue snapshot yet. Completion callbacks clean recent files directly.
        let cutoff = Date().addingTimeInterval(-86_400)
        for url in files where !urls.contains(url) {
            if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date < cutoff {
                removeSnapshot(url)
            }
        }
    }

    private func entryURL(_ id: String) throws -> URL {
        guard !id.isEmpty, id.utf8.count <= 128,
              id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 })
        else { throw CocoaError(.fileWriteInvalidFileName) }
        return directory.appendingPathComponent(id).appendingPathExtension("plist")
    }
}
