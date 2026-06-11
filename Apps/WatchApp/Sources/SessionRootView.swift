import SwiftUI
import Domain
import Persistence
import Session

/// Watch home: start a session, then watch live depth until you end it.
struct SessionRootView: View {
    @Environment(SessionCoordinator.self) private var session
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @State private var showMarkerPicker = false

    var body: some View {
        VStack(spacing: 12) {
            switch session.state {
            case .idle:
                Image(systemName: "water.waves")
                    .font(.largeTitle)
                    .foregroundStyle(.teal)
                Text("Freedive")
                    .font(.headline)
                Button("Start Session") {
                    Task { await session.start() }
                }
                .buttonStyle(.borderedProminent)

            case .active:
                Text(String(format: "%.1f m", session.currentDepthMeters))
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("Current Depth")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // Refresh once per second for the timer; while submerged show the
                // active-dive duration (highlighted), otherwise the session elapsed time.
                // TimelineView keeps redrawing in Always On Display at a reduced cadence.
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    if let diveElapsed = session.currentDiveElapsed {
                        Text(Duration.seconds(diveElapsed).formatted(.time(pattern: .minuteSecond)))
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(isLuminanceReduced ? AnyShapeStyle(.primary) : AnyShapeStyle(.teal))
                            .monospacedDigit()
                        // Measures time below the surface threshold, which begins
                        // before a descent qualifies as a counted dive — hence
                        // "Submerged" rather than "Dive Time".
                        Text("Submerged")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(Duration.seconds(session.elapsedTime).formatted(.time(pattern: .minuteSecond)))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Text("\(session.diveCount) dives · \(String(format: "%.1f", session.maxDepthMeters)) m max · \(session.markerCount) markers")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                // Controls are inert in Always On Display, so hide them to cut burn-in.
                if !isLuminanceReduced {
                    HStack {
                        Button {
                            showMarkerPicker = true
                        } label: {
                            Label("Mark", systemImage: "mappin")
                        }
                        .buttonStyle(.bordered)
                        Button("End", role: .destructive) {
                            Task { await session.stop() }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .padding()
        // Attached to the stable root so an open picker survives an Always On
        // Display transition (which removes the inline controls above).
        .confirmationDialog("Add Marker", isPresented: $showMarkerPicker) {
            ForEach(EventKind.allCases, id: \.self) { kind in
                Button(kind.rawValue.capitalized) {
                    session.addMarker(kind: kind)
                }
            }
        }
    }
}

#Preview {
    SessionRootView()
        .environment(
            SessionCoordinator(
                modelContext: try! DiveStore(inMemory: true).container.mainContext
            )
        )
}
