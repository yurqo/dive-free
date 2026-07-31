import SwiftUI
import SwiftData
import Domain
import Persistence

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
    /// The engine's latest report, driving the progress bar and its caption.
    @State private var progress: BackupProgress?
    /// Held so the Cancel button can cancel the in-flight export.
    @State private var exportTask: Task<Void, Never>?
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
            if isExporting {
                // Determinate wherever the engine can count items, so a long export
                // visibly advances instead of sitting on a spinner the user can't read.
                // `Cancel` is the reason the pipeline is async at all: the main thread
                // stays free to service this tap mid-export.
                VStack(alignment: .leading, spacing: 8) {
                    if let fraction = progress?.fraction {
                        ProgressView(value: fraction) { Text(progressLabel) }
                    } else {
                        ProgressView { Text(progressLabel) }
                    }
                    Button(role: .destructive) {
                        exportTask?.cancel()
                    } label: {
                        Text("Cancel Export")
                    }
                }
            } else {
                Button {
                    exportTask = Task { await runExport() }
                } label: {
                    Text("Export")
                }
            }
        }
    }

    /// A human sentence for the current phase, with an item count when there is one.
    private var progressLabel: String {
        guard let progress else { return String(localized: "Preparing…") }
        switch progress.phase {
        case .preparing:
            return String(localized: "Preparing…")
        case .voiceNotes:
            return progress.total > 0
                ? String(localized: "Copying voice notes — \(progress.completed) of \(progress.total)")
                : String(localized: "Copying voice notes…")
        case .photos:
            return progress.total > 0
                ? String(localized: "Copying photos — \(progress.completed) of \(progress.total)")
                : String(localized: "Copying photos…")
        case .compressing:
            return String(localized: "Compressing…")
        case .expanding, .sessions, .finished:
            return String(localized: "Finishing…")
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
        progress = BackupProgress(phase: .preparing)
        defer {
            isExporting = false
            progress = nil
            exportTask = nil
        }
        // Drop a previous run's archive before making another, so exporting twice in one
        // sitting can't leave two multi-gigabyte copies behind.
        discardExportedBackup()
        do {
            let url = try await BackupService.exportBackup(
                options: options,
                context: context,
                // The engine reports from whichever thread is doing the work, so hop back
                // to the main actor before touching view state.
                progress: { report in Task { @MainActor in progress = report } }
            )
            exportedDirectory = url.deletingLastPathComponent()
            backupToShare = SharedBackupFile(url: url)
        } catch is CancellationError {
            // The user cancelled; `exportBackup` already removed its temp tree, so there
            // is nothing to clean up and nothing to apologize for.
        } catch let error as ZipContainer.ZipError {
            // The zip writer's own size ceilings are the export-side failures worth naming;
            // anything else falls through to the diagnostic default below.
            switch error {
            case .entryTooLarge:
                errorMessage = String(localized: "This backup is too large to create. Individual files or the whole archive can't exceed 4 GB — try exporting without videos.")
            case .tooManyEntries:
                errorMessage = String(localized: "You have too many items to fit in a single backup.")
            default:
                errorMessage = String(localized: "Couldn't create the backup. Please try again. (\(error.localizedDescription))")
            }
        } catch {
            // Never a dead end: surface the underlying cause so a device-only failure is
            // diagnosable on the next attempt.
            errorMessage = String(localized: "Couldn't create the backup. Please try again. (\(error.localizedDescription))")
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
