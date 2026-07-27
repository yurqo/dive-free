import SwiftUI
import SwiftData
import Domain

/// Configures and runs a backup export: pick which heavy media to bundle (all off by
/// default), see a live, approximate size estimate per category, then export to a
/// `.zip` and share it. Presented as a sheet from Settings.
///
/// The estimate and the export both call ``BackupService``; PhotoKit resolution can
/// take a while (and may download iCloud-only originals), so both show progress and
/// the Export button is disabled while a run is in flight.
struct ExportBackupView: View {
    let context: ModelContext

    @Environment(\.dismiss) private var dismiss

    // Heavy-media toggles — deliberately NOT persisted: off each time, so the default
    // is always the smallest, safest archive.
    @State private var includeVoiceNotes = false
    @State private var includePhotos = false
    @State private var includeVideos = false

    @State private var estimate: BackupSizeEstimate?
    @State private var isEstimating = false
    @State private var isExporting = false
    @State private var errorMessage: String?
    @State private var backupToShare: SharedBackupFile?
    /// The temp directory holding the exported `.zip`, deleted once the share sheet closes
    /// (`backupToShare` is already nil by then, so the URL is remembered separately).
    @State private var exportedDirectory: URL?

    private var options: BackupExportOptions {
        BackupExportOptions(
            includeVoiceNotes: includeVoiceNotes,
            includePhotos: includePhotos,
            includeVideos: includeVideos
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                includeSection
                estimateSection
                exportSection
            }
            .navigationTitle("Export Backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isExporting)
                }
            }
            // Runs once: the per-category numbers don't depend on the toggles, so flipping
            // a switch just re-sums (see `estimateSection`) instead of re-sweeping
            // PhotoKit. SwiftUI cancels this task if the sheet closes mid-sweep.
            .task { await loadEstimate() }
            .sheet(item: $backupToShare, onDismiss: discardExportedBackup) { shared in
                ActivityView(activityItems: [shared.url])
            }
            .alert(
                "Backup Failed",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                ),
                presenting: errorMessage
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { Text($0) }
        }
    }

    @ViewBuilder private var includeSection: some View {
        Section {
            Toggle("Voice notes", isOn: $includeVoiceNotes)
            Toggle("Photos", isOn: $includePhotos)
            Toggle("Videos", isOn: $includeVideos)
        } header: {
            Text("Include originals")
        } footer: {
            Text("A backup always includes your sessions, spots, trips, and the photo gallery — its references and thumbnails. Turn these on to also bundle the full-size originals, which make the file much larger. Photos and videos re-import to your library on restore only if the originals are missing.")
        }
        .disabled(isExporting)
    }

    @ViewBuilder private var estimateSection: some View {
        Section {
            if isEstimating {
                HStack {
                    Text("Estimating size…")
                    Spacer()
                    ProgressView()
                }
            } else if let estimate {
                LabeledContent("Sessions & thumbnails") { Text(estimate.formatted(estimate.base)) }
                if includeVoiceNotes {
                    LabeledContent("Voice notes") { Text(estimate.formatted(estimate.voiceNotes)) }
                }
                if includePhotos {
                    LabeledContent("Photos") { Text(estimate.formatted(estimate.photos)) }
                }
                if includeVideos {
                    LabeledContent("Videos") { Text(estimate.formatted(estimate.videos)) }
                }
                LabeledContent("Estimated total") {
                    Text(estimate.formatted(estimate.total(with: options))).bold()
                }
            }
        } header: {
            Text("Estimated size")
        } footer: {
            Text("Approximate. Photos and videos may download from iCloud during export, which can take a while.")
        }
    }

    @ViewBuilder private var exportSection: some View {
        Section {
            Button {
                Task { await runExport() }
            } label: {
                HStack {
                    Text("Export")
                    if isExporting {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isExporting)
        }
    }

    private func loadEstimate() async {
        isEstimating = true
        let result = await BackupService.estimatedSizes(context: context)
        // A cancelled sweep (the sheet closed) must not touch state; `isEstimating` is
        // cleared either way so the spinner can never be left spinning.
        guard !Task.isCancelled else { return }
        estimate = result
        isEstimating = false
    }

    private func runExport() async {
        isExporting = true
        defer { isExporting = false }
        // Drop a previous run's archive before making another, so exporting twice in one
        // sitting can't leave two multi-gigabyte copies behind.
        discardExportedBackup()
        do {
            let url = try await BackupService.exportBackup(options: options, context: context)
            exportedDirectory = url.deletingLastPathComponent()
            backupToShare = SharedBackupFile(url: url)
        } catch {
            errorMessage = String(localized: "Couldn't create the backup. Please try again.")
        }
    }

    /// Deletes the temp directory holding the exported `.zip`.
    ///
    /// `BackupService.exportBackup` hands back a file in its own `tmp/<uuid>/` and makes
    /// us its owner. Without this, every export leaves another archive — potentially
    /// gigabytes — parked in `tmp`, which iOS only purges opportunistically, so repeated
    /// exports can fill the device and fail mid-write. It runs on the share sheet's
    /// `onDismiss`, i.e. after `UIActivityViewController` has finished copying the file to
    /// wherever the user sent it, never before.
    private func discardExportedBackup() {
        guard let dir = exportedDirectory else { return }
        exportedDirectory = nil
        try? FileManager.default.removeItem(at: dir)
    }
}

/// An `Identifiable` wrapper so a just-written backup file can drive a
/// `.sheet(item:)` share sheet.
struct SharedBackupFile: Identifiable {
    let id = UUID()
    let url: URL
}
