import SwiftUI
import MapKit
import SwiftData
import Domain
import Persistence

/// Strava-style session cropping: trim the surface tails before the first dive
/// and after the last dive. Two sliders (start/end) with fine-tune steppers, a
/// live map preview of the kept sub-path, and a running tally of what the crop
/// will drop. The actual trim is delegated to the tested Domain `cropped(to:)`
/// (via `applyCrop`), which clamps the range so a crop can never cut a dive.
struct SessionCropView: View {
    let session: SessionRecord

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// Snapshot of the session, computed once in `init`. `toDomain()` re-decodes the
    /// stored blobs, so we avoid recomputing it on every body pass / slider tick.
    private let domain: DiveSession

    /// Crop-start handle, as an instant within `croppableStartRange`.
    @State private var cropStart: Date
    /// Crop-end handle, as an instant within `croppableEndRange`.
    @State private var cropEnd: Date
    @State private var showConfirm = false

    /// Smallest duration a crop may leave — keeps the two handles from crossing on
    /// a zero-dive session where the start/end ranges span the whole session.
    private static let minimumKeptDuration: TimeInterval = 10

    init(session: SessionRecord) {
        self.session = session
        let domain = session.toDomain()
        self.domain = domain
        _cropStart = State(initialValue: domain.startTime)
        _cropEnd = State(initialValue: domain.endTime ?? domain.startTime)
    }

    /// True when the session never ended (live/mirrored). It can't be cropped —
    /// `applyCrop` would force-finalize it — so Save is disabled.
    private var isCroppable: Bool { domain.endTime != nil }

    /// The kept window, order-safe against the two handles crossing.
    private var range: ClosedRange<Date> {
        min(cropStart, cropEnd)...max(cropStart, cropEnd)
    }

    /// Live crop preview: the trimmed session plus the dropped-artifact tally.
    /// Recomputed once per body (threaded through), not per read site.
    private var preview: SessionCropResult { domain.cropped(to: range) }

    /// True when the current handles would drop nothing (no series/markers fall
    /// outside the range and the bounds are unchanged) — Save is disabled.
    private func isNoOp(_ p: SessionCropResult) -> Bool {
        p.droppedTrackPoints == 0
            && p.droppedHeartRateSamples == 0
            && p.droppedTemperatureSamples == 0
            && p.droppedMarkers.isEmpty
            && p.session.startTime == domain.startTime
            && p.session.endTime == domain.endTime
    }

    var body: some View {
        let p = preview
        VStack(spacing: 0) {
            mapSection(domain)
            Form {
                statsSection(p)
                startPointSection(domain)
                endPointSection(domain)
            }
        }
        .navigationTitle("Crop")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { showConfirm = true }
                    .disabled(!isCroppable || isNoOp(p))
            }
        }
        .confirmationDialog("Crop this session?", isPresented: $showConfirm, titleVisibility: .visible) {
            Button("Crop Session", role: .destructive) {
                applyCrop(to: session, range: range, in: modelContext)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage(p))
        }
        .unitsAware()
    }

    // MARK: - Map

    @ViewBuilder
    private func mapSection(_ domain: DiveSession) -> some View {
        if !domain.effectiveTrack.isEmpty {
            CropTrackMapView(session: domain, range: range)
                .frame(height: 240)
        } else {
            ZStack {
                Rectangle().fill(.quaternary)
                Label("No location recorded", systemImage: "location.slash")
                    .foregroundStyle(.secondary)
            }
            .frame(height: 140)
        }
    }

    // MARK: - Stats

    private func statsSection(_ p: SessionCropResult) -> some View {
        let duration = range.upperBound.timeIntervalSince(range.lowerBound)
        let keptMarkers = p.session.markers.count
        let droppedMarkers = p.droppedMarkers.count
        return Section {
            HStack {
                stat("Duration", value: Self.durationLabel(duration))
                Divider()
                stat("Distance", value: DistanceFormat.string(p.session.surfaceDistanceMeters))
            }
            HStack {
                stat("Dives", value: "\(p.session.dives.count)")
                Divider()
                markerStat(kept: keptMarkers, dropped: droppedMarkers)
            }
        }
    }

    private func stat(_ title: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func markerStat(kept: Int, dropped: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Markers")
                .font(.caption)
                .foregroundStyle(.secondary)
            if dropped > 0 {
                // Separate strings keep pluralization catalog-friendly (no
                // concatenation of an inflected fragment into a sentence).
                HStack(spacing: 4) {
                    Text("\(kept)").font(.headline).monospacedDigit()
                    Text("· \(dropped) removed")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else {
                Text("\(kept)").font(.headline).monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Sliders

    private func startPointSection(_ domain: DiveSession) -> some View {
        Section("Start Point") {
            slider(value: $cropStart, in: startBounds,
                   earlierLabel: "Nudge start earlier",
                   laterLabel: "Nudge start later")
        }
    }

    private func endPointSection(_ domain: DiveSession) -> some View {
        Section("End Point") {
            slider(value: $cropEnd, in: endBounds,
                   earlierLabel: "Nudge end earlier",
                   laterLabel: "Nudge end later")
        }
    }

    /// Effective start-handle range: the Domain range, but never allowed to reach
    /// within `minimumKeptDuration` of the current end handle. For a session WITH
    /// dives the Domain ranges are already disjoint (start ends at the first dive),
    /// so this clamp never binds; it only matters for a zero-dive session where the
    /// two ranges span the whole session and the handles could otherwise cross.
    private var startBounds: ClosedRange<Date> {
        let base = domain.croppableStartRange
        let ceiling = cropEnd.addingTimeInterval(-Self.minimumKeptDuration)
        let upper = min(base.upperBound, ceiling)
        // Degrade gracefully if the session is shorter than the minimum.
        return base.lowerBound...max(base.lowerBound, upper)
    }

    /// Effective end-handle range: the Domain range, but never allowed to reach
    /// within `minimumKeptDuration` of the current start handle. Same rationale as
    /// `startBounds` — only binds on a zero-dive session.
    private var endBounds: ClosedRange<Date> {
        let base = domain.croppableEndRange
        let floor = cropStart.addingTimeInterval(Self.minimumKeptDuration)
        let lower = max(base.lowerBound, floor)
        // Degrade gracefully if the session is shorter than the minimum.
        return min(base.upperBound, lower)...base.upperBound
    }

    /// A slider over a date range (its `value` is bound as a `TimeInterval` offset
    /// from the range base) plus a `< value >` fine-tune row. The readout label is
    /// always session-relative (offset from `domain.startTime`) for consistency.
    @ViewBuilder
    private func slider(
        value: Binding<Date>,
        in bounds: ClosedRange<Date>,
        earlierLabel: LocalizedStringKey,
        laterLabel: LocalizedStringKey
    ) -> some View {
        let base = bounds.lowerBound
        let span = max(0, bounds.upperBound.timeIntervalSince(base))
        let offset = Binding(
            get: { max(0, min(span, value.wrappedValue.timeIntervalSince(base))) },
            set: { value.wrappedValue = base.addingTimeInterval($0) }
        )
        let sessionOffset = value.wrappedValue.timeIntervalSince(domain.startTime)

        VStack(spacing: 8) {
            HStack {
                NudgeButton(
                    systemImage: "chevron.left",
                    accessibilityLabel: earlierLabel,
                    step: { nudge(value, by: -$0, in: bounds) }
                )
                Spacer()
                Text(Self.durationLabel(sessionOffset))
                    .font(.headline)
                    .monospacedDigit()
                Spacer()
                NudgeButton(
                    systemImage: "chevron.right",
                    accessibilityLabel: laterLabel,
                    step: { nudge(value, by: $0, in: bounds) }
                )
            }
            Slider(value: offset, in: 0...max(span, 1))
                .disabled(span <= 0)
                .tint(.orange)
        }
    }

    /// Move `value` by `seconds` (positive = later), clamped into `bounds`.
    private func nudge(_ value: Binding<Date>, by seconds: TimeInterval, in bounds: ClosedRange<Date>) {
        let moved = value.wrappedValue.addingTimeInterval(seconds)
        value.wrappedValue = min(max(moved, bounds.lowerBound), bounds.upperBound)
    }

    // MARK: - Confirmation copy

    /// Destructive-action message listing what the crop permanently removes.
    /// Each line is emitted only when its count is non-zero; a trailing note
    /// calls out voice notes among the dropped markers.
    private func confirmationMessage(_ p: SessionCropResult) -> String {
        var lines: [String] = []

        let bounds = String(
            localized: "New range: \(Self.durationLabel(range.upperBound.timeIntervalSince(range.lowerBound)))"
        )
        lines.append(bounds)

        if p.droppedTrackPoints > 0 {
            lines.append(String(localized: "Removes \(p.droppedTrackPoints) track points"))
        }
        if p.droppedHeartRateSamples > 0 {
            lines.append(String(localized: "Removes \(p.droppedHeartRateSamples) heart-rate samples"))
        }
        if p.droppedTemperatureSamples > 0 {
            lines.append(String(localized: "Removes \(p.droppedTemperatureSamples) temperature samples"))
        }
        if !p.droppedMarkers.isEmpty {
            lines.append(String(localized: "Removes \(p.droppedMarkers.count) markers"))
        }
        if p.droppedMarkers.contains(where: \.hasAudio) {
            lines.append(String(localized: "Attached voice notes are removed too."))
        }

        lines.append(String(localized: "This can't be undone."))
        return lines.joined(separator: "\n")
    }

    // MARK: - Formatting

    /// Session duration/offset, localized via the same formatter the rest of the app
    /// uses (`SessionDetailView`'s `.time(pattern: .hourMinuteSecond)`).
    private static func durationLabel(_ interval: TimeInterval) -> String {
        Duration.seconds(max(0, interval)).formatted(.time(pattern: .hourMinuteSecond))
    }
}

// MARK: - Nudge button

/// A chevron fine-tune button: a single tap nudges by 1 s; press-and-hold
/// repeats, accelerating from ~5 s toward ~15 s per tick until released.
private struct NudgeButton: View {
    let systemImage: String
    let accessibilityLabel: LocalizedStringKey
    /// Applies a nudge of the given magnitude in seconds.
    let step: (TimeInterval) -> Void

    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        Image(systemName: systemImage)
            .font(.title3)
            .foregroundStyle(.tint)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .onTapGesture { step(1) }
            .onLongPressGesture(
                minimumDuration: 0.3,
                perform: {},
                onPressingChanged: { pressing in
                    if pressing { startRepeating() } else { stopRepeating() }
                }
            )
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.isButton)
    }

    private func startRepeating() {
        repeatTask?.cancel()
        repeatTask = Task { @MainActor in
            // Hold before the first repeat so a long-press doesn't double-fire
            // with the tap; then repeat, accelerating 5 → 15 s per tick.
            try? await Task.sleep(for: .milliseconds(400))
            var magnitude: TimeInterval = 5
            while !Task.isCancelled {
                step(magnitude)
                magnitude = min(15, magnitude + 2)
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    private func stopRepeating() {
        repeatTask?.cancel()
        repeatTask = nil
    }
}

// MARK: - Crop map

/// A dedicated map for the crop screen (kept separate from `SessionTrackMapView`
/// so the detail screen never regresses). Draws the full surface path muted,
/// the kept sub-path in the accent colour, live start/end pins, and every event
/// marker — greyed when its timestamp falls outside the kept range.
private struct CropTrackMapView: View {
    let session: DiveSession
    let range: ClosedRange<Date>

    private var fullPath: [CLLocationCoordinate2D] {
        session.effectiveTrack.map(\.location.coordinate)
    }

    private var keptPath: [CLLocationCoordinate2D] {
        session.effectiveTrack
            .filter { range.contains($0.timestamp) }
            .map(\.location.coordinate)
    }

    var body: some View {
        Map(initialPosition: .automatic) {
            if fullPath.count >= 2 {
                MapPolyline(coordinates: fullPath)
                    .stroke(.gray.opacity(0.5), lineWidth: 3)
            }
            if keptPath.count >= 2 {
                MapPolyline(coordinates: keptPath)
                    .stroke(.orange, lineWidth: 4)
            }

            if let start = session.surfaceLocation(at: range.lowerBound) {
                Annotation("Start", coordinate: start.coordinate) {
                    Circle()
                        .fill(.green)
                        .frame(width: 16, height: 16)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .shadow(radius: 1)
                }
                .annotationTitles(.hidden)
            }
            if let end = session.surfaceLocation(at: range.upperBound) {
                Annotation("End", coordinate: end.coordinate) {
                    Image(systemName: "flag.checkered")
                        .font(.body)
                        .padding(6)
                        .background(Circle().fill(.thinMaterial))
                        .shadow(radius: 1)
                }
                .annotationTitles(.hidden)
            }

            ForEach(session.markers) { marker in
                if let geo = session.markerLocation(marker) {
                    let inRange = range.contains(marker.timestamp)
                    Annotation(marker.kind.label, coordinate: geo.coordinate) {
                        markerView(marker.kind.emoji, inRange: inRange)
                    }
                    .annotationTitles(.hidden)
                }
            }
        }
    }

    @ViewBuilder
    private func markerView(_ emoji: String, inRange: Bool) -> some View {
        if inRange {
            Text(emoji)
                .font(.body)
                .padding(4)
                .background(Circle().fill(.thinMaterial))
                .shadow(radius: 1)
        } else {
            // Dropped by the crop: desaturated, no material — signals removal.
            Text(emoji)
                .font(.body)
                .padding(4)
                .grayscale(1)
                .opacity(0.4)
        }
    }
}

private extension GeoPoint {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
