import SwiftUI

/// First page of the watch home pager: start a session. (Sessions and Settings
/// are the adjacent pages — see `WatchRootView`.)
struct StartView: View {
    @Environment(SessionCoordinator.self) private var session
    @State private var showGuide = false

    var body: some View {
        // Bottom-weighted: a larger top spacer than bottom (2:1) drops the icon +
        // Start group toward the lower half and pins "How to use?" to the bottom,
        // just above the page indicator.
        VStack(spacing: 10) {
            Spacer()
            Spacer()
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
            }
            Spacer()
            Button { showGuide = true } label: {
                Label("How to use?", systemImage: "questionmark.circle")
                    .font(.caption2)
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.teal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
        .sheet(isPresented: $showGuide) { WatchUserGuideView() }
    }
}
