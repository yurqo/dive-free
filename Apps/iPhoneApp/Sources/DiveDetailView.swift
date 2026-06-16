import SwiftUI
import Domain

/// A single dive's detail: headline figures plus its depth-profile chart. Pushed
/// from a dive row in the session's segment list.
struct DiveDetailView: View {
    let dive: Dive
    let index: Int
    var markers: [EventMarker] = []

    var body: some View {
        List {
            Section {
                LabeledContent("Max depth", value: DepthFormat.string(dive.maxDepthMeters))
                LabeledContent("Duration", value: Duration.seconds(dive.duration).formatted(.time(pattern: .minuteSecond)))
                LabeledContent("Start", value: dive.startTime.formatted(date: .omitted, time: .standard))
            }
            Section("Depth profile") {
                DepthChartView(dive: dive, markers: markers)
            }
        }
        .navigationTitle("Dive \(index)")
        .navigationBarTitleDisplayMode(.inline)
    }
}
