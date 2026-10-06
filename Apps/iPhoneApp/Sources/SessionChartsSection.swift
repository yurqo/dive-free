import Charts
import Domain
import SwiftUI

private let sessionChartAxisColumnWidth: CGFloat = 60

/// The session timeline uses aligned plots because depth, heart rate, and water
/// temperature have different units and meaningful Y scales. A shared time
/// window keeps the three charts in sync without normalizing away real values.
struct SessionChartsSection: View {
    let session: DiveSession

    @State private var isZoomed: Bool
    @State private var zoomWindowStart: Date?
    @State private var dragAnchor: Date?

    private let chartHeight: CGFloat = 142

    init(session: DiveSession) {
        self.session = session
        #if DEBUG
        _isZoomed = State(initialValue: ProcessInfo.processInfo.arguments.contains("--screenshot-chart-zoomed-in"))
        #else
        _isZoomed = State(initialValue: false)
        #endif
    }

    private var hasDepth: Bool {
        session.dives.contains { !$0.samples.isEmpty }
    }

    private var hasHeartRate: Bool { !session.heartRateSamples.isEmpty }
    private var hasTemperature: Bool { !session.temperatureSamples.isEmpty }
    private var hasCharts: Bool { hasDepth || hasHeartRate || hasTemperature }

    private var sessionStart: Date { session.startTime }
    private var viewport: SessionChartViewport {
        SessionChartViewport(start: sessionStart, end: sessionEnd)
    }

    private var sessionEnd: Date {
        var dates: [Date] = [session.startTime]
        if let endTime = session.endTime { dates.append(endTime) }
        for dive in session.dives {
            dates.append(dive.startTime)
            dates.append(dive.endTime)
            dates.append(contentsOf: dive.samples.map(\.timestamp))
        }
        dates.append(contentsOf: session.heartRateSamples.map(\.timestamp))
        dates.append(contentsOf: session.temperatureSamples.map(\.timestamp))
        return max(dates.max() ?? session.startTime, session.startTime.addingTimeInterval(1))
    }

    private var canZoom: Bool { viewport.canZoom }
    private var chartRange: ClosedRange<Date> { viewport.visibleRange(zoomed: isZoomed, startingAt: zoomWindowStart) }

    private var chartCount: Int {
        [hasDepth, hasHeartRate, hasTemperature].filter { $0 }.count
    }

    @ViewBuilder
    var body: some View {
        if hasCharts {
            Section {
                GeometryReader { geometry in
                    VStack(spacing: 4) {
                        if hasDepth {
                            SessionDepthProfileChart(dives: session.dives, range: chartRange)
                                .frame(height: chartHeight)
                        }
                        if hasHeartRate {
                            SessionMetricChart(
                                points: session.heartRateSamples.enumerated().map {
                                    SessionMetricPoint(id: $0.offset, timestamp: $0.element.timestamp, value: $0.element.bpm)
                                },
                                title: "Heart rate",
                                axisLabel: "bpm",
                                tint: .red,
                                range: chartRange,
                                showsTimeLabels: !hasTemperature
                            )
                            .frame(height: chartHeight)
                        }
                        if hasTemperature {
                            SessionMetricChart(
                                points: session.temperatureSamples.enumerated().map {
                                    SessionMetricPoint(
                                        id: $0.offset,
                                        timestamp: $0.element.timestamp,
                                        value: TemperatureFormat.displayValue($0.element.celsius)
                                    )
                                },
                                title: "Temperature",
                                axisLabel: TemperatureFormat.unitLabel(),
                                tint: .green,
                                range: chartRange,
                                showsTimeLabels: true
                            )
                            .frame(height: chartHeight)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .simultaneousGesture(horizontalPan(in: geometry.size.width))
                    .accessibilityIdentifier("session.charts.group")
                }
                .frame(height: CGFloat(chartCount) * chartHeight + CGFloat(max(0, chartCount - 1)) * 4)

                if isZoomed {
                    HStack(spacing: 8) {
                        Label("Swipe charts to explore 5-minute windows", systemImage: "arrow.left.and.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("session.charts.zoom.hint")
                        Spacer(minLength: 4)
                        Text(chartRangeLabel)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("session.charts.window")
                    }
                }
            } header: {
                HStack {
                    Text("Session profile")
                    Spacer()
                    Button(action: toggleZoom) {
                        Image(systemName: isZoomed ? "minus.magnifyingglass" : "plus.magnifyingglass")
                            .font(.body.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canZoom)
                    .accessibilityIdentifier("session.charts.zoom")
                    .accessibilityLabel(isZoomed ? Text("Zoom out") : Text("Zoom in"))
                }
            }
        }
    }

    private func toggleZoom() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isZoomed.toggle()
            zoomWindowStart = sessionStart
            dragAnchor = nil
        }
    }

    private var chartRangeLabel: String {
        let start = chartRange.lowerBound.formatted(date: .omitted, time: .shortened)
        let end = chartRange.upperBound.formatted(date: .omitted, time: .shortened)
        return "\(start) – \(end)"
    }

    private func horizontalPan(in width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard isZoomed, canZoom,
                      abs(value.translation.width) > abs(value.translation.height),
                      width > 0 else { return }
                let anchor = dragAnchor ?? chartRange.lowerBound
                dragAnchor = anchor
                let visibleSeconds = chartRange.upperBound.timeIntervalSince(chartRange.lowerBound)
                zoomWindowStart = viewport.pannedStart(
                    anchor: anchor,
                    horizontalTranslation: Double(value.translation.width),
                    viewportWidth: Double(width),
                    visibleDuration: visibleSeconds
                )
            }
            .onEnded { _ in dragAnchor = nil }
    }
}

private struct SessionDepthProfileChart: View {
    let dives: [Dive]
    let range: ClosedRange<Date>

    var body: some View {
        Chart {
            ForEach(dives) { dive in
                ForEach(Array(dive.samples.sorted { $0.timestamp < $1.timestamp }.enumerated()), id: \.offset) { _, sample in
                    LineMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Depth", DepthFormat.displayDepth(sample.depthMeters)),
                        series: .value("Dive", dive.id.uuidString)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.teal)
                }
            }
        }
        .chartXScale(domain: range)
        .chartYScale(domain: .automatic(includesZero: true, reversed: true))
        .chartYAxis { sessionRightYAxis(tint: .teal) }
        .chartYAxisLabel(position: .topTrailing) {
            Text(DepthFormat.axisLabel())
                .frame(width: sessionChartAxisColumnWidth, alignment: .leading)
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
        .chartXAxis { timeAxis(showsLabels: false) }
        // Swift Charts otherwise lets marks whose timestamps are outside the
        // visible domain draw into the trailing axis gutter (most noticeable for
        // dense heart-rate data while zoomed in).
        .chartPlotStyle { plot in plot.clipped() }
        .overlay(alignment: .topLeading) {
            Text("Depth profile")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.teal)
                .padding(.leading, 4)
                .padding(.top, 2)
        }
    }
}

private struct SessionMetricPoint: Identifiable {
    let id: Int
    let timestamp: Date
    let value: Double
}

private struct SessionMetricChart: View {
    let points: [SessionMetricPoint]
    let title: LocalizedStringKey
    let axisLabel: String
    let tint: Color
    let range: ClosedRange<Date>
    let showsTimeLabels: Bool

    var body: some View {
        Chart(points) { point in
            LineMark(
                x: .value("Time", point.timestamp),
                y: .value(axisLabel, point.value)
            )
            .interpolationMethod(.monotone)
            .foregroundStyle(tint)
        }
        .chartXScale(domain: range)
        .chartYScale(domain: valueDomain)
        .chartYAxis { sessionRightYAxis(tint: tint) }
        .chartYAxisLabel(position: .topTrailing) {
            Text(axisLabel)
                .frame(width: sessionChartAxisColumnWidth, alignment: .leading)
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
        .chartXAxis { timeAxis(showsLabels: showsTimeLabels) }
        .chartPlotStyle { plot in plot.clipped() }
        .overlay(alignment: .topLeading) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.leading, 4)
                .padding(.top, 2)
        }
    }

    /// Keep a metric's scale stable while panning, but use the session's actual
    /// range rather than starting heart rate and temperature axes at zero.
    private var valueDomain: ClosedRange<Double> {
        guard let minimum = points.map(\.value).min(),
              let maximum = points.map(\.value).max() else { return 0...1 }
        let step = axisLabel == "bpm" ? 5.0 : (axisLabel == "°F" ? 2.0 : 1.0)
        let padding = max((maximum - minimum) * 0.15, step)
        let lower = floor((minimum - padding) / step) * step
        let upper = ceil((maximum + padding) / step) * step
        return lower...(upper > lower ? upper : lower + step)
    }
}

private func sessionRightYAxis(tint: Color) -> some AxisContent {
    AxisMarks(position: .trailing) { value in
        AxisGridLine()
        AxisTick().foregroundStyle(tint.opacity(0.7))
        AxisValueLabel {
            if let number = value.as(Double.self) {
                Text(number, format: .number.precision(.fractionLength(0...1)))
                    .frame(width: sessionChartAxisColumnWidth, alignment: .leading)
                    .foregroundStyle(tint)
            }
        }
    }
}

private func timeAxis(showsLabels: Bool) -> some AxisContent {
    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
        AxisGridLine()
        AxisTick()
        if showsLabels {
            AxisValueLabel(format: .dateTime.hour().minute())
        } else {
            AxisValueLabel().foregroundStyle(.clear)
        }
    }
}
