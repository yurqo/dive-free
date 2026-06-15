import SwiftUI

/// First page of the watch home pager: start a session. (Sessions and Settings
/// are the adjacent pages — see `WatchRootView`.)
struct StartView: View {
    @Environment(SessionCoordinator.self) private var session

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "water.waves")
                .font(.largeTitle)
                .foregroundStyle(.teal)
            Text("Freedive")
                .font(.headline)
            Button(session.startError == nil ? "Start Session" : "Try Again") {
                Task { await session.start() }
            }
            .buttonStyle(.borderedProminent)
            if let startError = session.startError {
                Text(startError)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Swipe for sessions & settings")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 4)
    }
}
