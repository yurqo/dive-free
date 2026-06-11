import SwiftUI
import Persistence
import Session

/// Watch home: start a session, then watch live depth until you end it.
struct SessionRootView: View {
    @Environment(SessionCoordinator.self) private var session

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
                // Refresh once per second for the timer without manual State.
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(Duration.seconds(session.elapsedTime).formatted(.time(pattern: .minuteSecond)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Button("End Session", role: .destructive) {
                    Task { await session.stop() }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
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
