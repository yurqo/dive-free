import Charts
import Domain
import SwiftUI

private let sessionChartAxisColumnWidth: CGFloat = 40

/// The session timeline uses aligned plots because depth, heart rate, and water
/// temperature have different units and meaningful Y scales. A shared time
/// window keeps the charts in sync without normalizing away real values.
struct SessionChartsSection: View {
    let session: DiveSession

    @State private var zoomDuration: TimeInterval?
    @State private var zoomWindowStart: Date?
    @State private var dragAnchor: Date?
    @State private var hidesSurfaceIntervals = false
    @State private var pinchStartRange: ClosedRange<Date>?
    @State private var pinchStartDuration: TimeInterval?

    private let chartHeight: CGFloat = 142

    init(session: DiveSession) {
        self.session = session
        #if DEBUG
        _zoomDuration = State(initialValue: ProcessInfo.processInfo.arguments.contains("--screenshot-chart-zoomed-in")
            ? SessionChartViewport.maximumZoomDuration
            : nil)
        #else
        _zoomDuration = State(initialValue: nil)
        #endif
    }

    private var hasDepth: Bool {
        session.dives.contains { !$0.samples.isEmpty }
    }

    private var hasHeartRate: Bool { !session.heartRateSamples.isEmpty }
    private var hasTemperature: Bool { !session.temperatureSamples.isEmpty }
    private var hasCharts: Bool { hasDepth || hasHeartRate || hasTemperature }

    private var sessionStart: Date { session.startTime }

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

    private func makeTimeline(hidingSurfaceIntervals: Bool) -> SessionChartTimeline {
        SessionChartTimeline(
            start: sessionStart,
            end: sessionEnd,
            diveIntervals: session.dives.map { $0.startTime...$0.endTime },
            hidesSurfaceIntervals: hidingSurfaceIntervals
        )
    }

    private var chartTimeline: SessionChartTimeline {
        makeTimeline(hidingSurfaceIntervals: hidesSurfaceIntervals)
    }

    private var hasSurfaceIntervals: Bool {
        makeTimeline(hidingSurfaceIntervals: false).hasSurfaceIntervals
    }

    private var firstDiveChartStart: Date? {
        guard let firstDive = session.dives.min(by: { $0.startTime < $1.startTime }) else { return nil }
        return chartTimeline.chartTime(for: firstDive.startTime)
    }

    private var viewport: SessionChartViewport {
        SessionChartViewport(start: chartTimeline.chartStart, end: chartTimeline.chartEnd)
    }

    private var canZoom: Bool { viewport.canZoom }
    private var isZoomed: Bool {
        guard canZoom, let zoomDuration else { return false }
        return zoomDuration < viewport.duration - 0.5
    }

    private var chartRange: ClosedRange<Date> {
        viewport.visibleRange(duration: isZoomed ? zoomDuration : nil, startingAt: zoomWindowStart)
    }

    private var chartCount: Int {
        [hasDepth, hasHeartRate, hasTemperature].filter { $0 }.count
    }

    private var heartRatePoints: [SessionMetricPoint] {
        session.heartRateSamples.enumerated().compactMap { index, sample in
            guard let date = chartTimeline.chartTime(for: sample.timestamp) else { return nil }
            return SessionMetricPoint(
                id: index,
                timestamp: date,
                value: sample.bpm,
                series: chartTimeline.seriesIndex(for: sample.timestamp)
            )
        }
    }

    private var temperaturePoints: [SessionMetricPoint] {
        session.temperatureSamples.enumerated().compactMap { index, sample in
            guard let date = chartTimeline.chartTime(for: sample.timestamp) else { return nil }
            return SessionMetricPoint(
                id: index,
                timestamp: date,
                value: TemperatureFormat.displayValue(sample.celsius),
                series: chartTimeline.seriesIndex(for: sample.timestamp)
            )
        }
    }

    @ViewBuilder
    var body: some View {
        if hasCharts {
            Section {
                GeometryReader { geometry in
                    chartGroup(width: geometry.size.width)
                }
                .frame(height: CGFloat(chartCount) * chartHeight + CGFloat(max(0, chartCount - 1)) * 4)

                if hasSurfaceIntervals {
                    Toggle("Hide surface intervals", isOn: Binding(
                        get: { hidesSurfaceIntervals },
                        set: { value in
                            withAnimation(.easeInOut(duration: 0.2)) {
                                hidesSurfaceIntervals = value
                                zoomWindowStart = makeTimeline(hidingSurfaceIntervals: value).chartStart
                                dragAnchor = nil
                            }
                        }
                    ))
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("session.charts.hideSurfaceIntervals")
                }

                if isZoomed {
                    HStack(spacing: 8) {
                        Label("Swipe to explore", systemImage: "arrow.left.and.right")
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
                    .accessibilityLabel(nextZoomAccessibilityLabel)
                }
            }
        }
    }

    @ViewBuilder
    private func chartGroup(width: CGFloat) -> some View {
        let charts = VStack(spacing: 4) {
            if hasDepth {
                SessionDepthProfileChart(
                    dives: session.dives,
                    timeline: chartTimeline,
                    range: chartRange,
                    elapsedTimeOrigin: hidesSurfaceIntervals ? chartTimeline.chartStart : nil,
                    includesSurfaceInScale: !isZoomed
                )
                .frame(height: chartHeight)
            }
            if hasHeartRate {
                SessionMetricChart(
                    points: heartRatePoints,
                    title: "Heart rate",
                    axisLabel: "bpm",
                    tint: .red,
                    range: chartRange,
                    showsTimeLabels: !hasTemperature,
                    elapsedTimeOrigin: hidesSurfaceIntervals ? chartTimeline.chartStart : nil
                )
                .frame(height: chartHeight)
            }
            if hasTemperature {
                SessionMetricChart(
                    points: temperaturePoints,
                    title: "Temperature",
                    axisLabel: TemperatureFormat.unitLabel(),
                    tint: .green,
                    range: chartRange,
                    showsTimeLabels: true,
                    elapsedTimeOrigin: hidesSurfaceIntervals ? chartTimeline.chartStart : nil
                )
                .frame(height: chartHeight)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityIdentifier("session.charts.group")

        if canZoom {
            if isZoomed {
                charts
                    .simultaneousGesture(horizontalPan(in: width))
                    .simultaneousGesture(pinchZoom())
            } else {
                charts.simultaneousGesture(pinchZoom())
            }
        } else {
            charts
        }
    }

    private var nextZoomAccessibilityLabel: Text {
        guard let zoomDuration, isZoomed else {
            return Text(LocalizedStringKey(viewport.duration > SessionChartViewport.maximumZoomDuration
                ? "Zoom to 5 minutes"
                : "Zoom to 1 minute"))
        }
        return Text(LocalizedStringKey(zoomDuration > SessionChartViewport.minimumZoomDuration + 1
            ? "Zoom to 1 minute"
            : "Zoom to full session"))
    }

    private func toggleZoom() {
        withAnimation(.easeInOut(duration: 0.2)) {
            if !isZoomed {
                zoomDuration = viewport.duration > SessionChartViewport.maximumZoomDuration
                    ? SessionChartViewport.maximumZoomDuration
                    : SessionChartViewport.minimumZoomDuration
                zoomWindowStart = firstDiveChartStart ?? viewport.start
            } else if (zoomDuration ?? 0) > SessionChartViewport.minimumZoomDuration + 1 {
                zoomDuration = SessionChartViewport.minimumZoomDuration
                zoomWindowStart = chartRange.lowerBound
            } else {
                zoomDuration = nil
                zoomWindowStart = viewport.start
            }
            dragAnchor = nil
        }
    }

    private var chartRangeLabel: String {
        if hidesSurfaceIntervals {
            let start = Duration.seconds(chartRange.lowerBound.timeIntervalSince(chartTimeline.chartStart))
                .formatted(.time(pattern: .minuteSecond))
            let end = Duration.seconds(chartRange.upperBound.timeIntervalSince(chartTimeline.chartStart))
                .formatted(.time(pattern: .minuteSecond))
            return "\(start) – \(end)"
        }
        if chartRange.upperBound.timeIntervalSince(chartRange.lowerBound) <= SessionChartViewport.minimumZoomDuration + 1 {
            let format = Date.FormatStyle(date: .omitted, time: .shortened).second()
            return "\(chartRange.lowerBound.formatted(format)) – \(chartRange.upperBound.formatted(format))"
        }
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
                zoomWindowStart = viewport.pannedStart(
                    anchor: anchor,
                    horizontalTranslation: Double(value.translation.width),
                    viewportWidth: Double(width),
                    visibleDuration: chartRange.upperBound.timeIntervalSince(chartRange.lowerBound)
                )
            }
            .onEnded { _ in dragAnchor = nil }
    }

    private func pinchZoom() -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard canZoom, value.magnification > 0 else { return }
                if pinchStartRange == nil {
                    pinchStartRange = chartRange
                    pinchStartDuration = chartRange.upperBound.timeIntervalSince(chartRange.lowerBound)
                }
                guard let startingRange = pinchStartRange,
                      let startingDuration = pinchStartDuration else { return }

                let requestedDuration = startingDuration / Double(value.magnification)
                let newDuration = min(max(requestedDuration, SessionChartViewport.minimumZoomDuration), viewport.duration)
                let newStart = viewport.startKeepingAnchor(
                    currentRange: startingRange,
                    anchorFraction: Double(value.startAnchor.x),
                    windowDuration: newDuration
                )
                zoomDuration = newDuration < viewport.duration - 0.5 ? newDuration : nil
                zoomWindowStart = newStart
            }
            .onEnded { _ in
                pinchStartRange = nil
                pinchStartDuration = nil
            }
    }
}

private struct SessionDepthProfileChart: View {
    let dives: [Dive]
    let timeline: SessionChartTimeline
    let range: ClosedRange<Date>
    let elapsedTimeOrigin: Date?
    let includesSurfaceInScale: Bool

    var body: some View {
        VStack(spacing: 0) {
            chartHeader(title: Text("Depth profile"), unit: DepthFormat.unitLabel(), tint: .teal)
            Chart {
                ForEach(dives) { dive in
                    let points = dive.samples.sorted { $0.timestamp < $1.timestamp }.enumerated().compactMap { index, sample in
                        timeline.chartTime(for: sample.timestamp).map { date in
                            SessionDepthChartPoint(id: index, timestamp: date, depth: DepthFormat.displayDepth(sample.depthMeters))
                        }
                    }.filter { range.contains($0.timestamp) }
                    ForEach(points) { point in
                        LineMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Depth", point.depth),
                            series: .value("Dive", dive.id.uuidString)
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(.teal)
                    }
                }
            }
            .chartXScale(domain: range)
            .chartYScale(domain: .automatic(includesZero: includesSurfaceInScale, reversed: true))
            .chartYAxis { sessionLeftYAxis(tint: .teal) }
            .chartXAxis {
                timeAxis(
                    showsLabels: false,
                    elapsedTimeOrigin: elapsedTimeOrigin,
                    showsSeconds: range.upperBound.timeIntervalSince(range.lowerBound) <= SessionChartViewport.minimumZoomDuration + 1
                )
            }
            .chartPlotStyle { plot in plot.clipped() }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct SessionDepthChartPoint: Identifiable {
    let id: Int
    let timestamp: Date
    let depth: Double
}

private struct SessionMetricPoint: Identifiable {
    let id: Int
    let timestamp: Date
    let value: Double
    let series: Int
}

private struct SessionMetricChart: View {
    let points: [SessionMetricPoint]
    let title: LocalizedStringKey
    let axisLabel: String
    let tint: Color
    let range: ClosedRange<Date>
    let showsTimeLabels: Bool
    let elapsedTimeOrigin: Date?

    var body: some View {
        VStack(spacing: 0) {
            chartHeader(title: Text(title), unit: axisLabel, tint: tint)
            Chart(visiblePoints) { point in
                LineMark(
                    x: .value("Time", point.timestamp),
                    y: .value(axisLabel, point.value),
                    series: .value("Timeline segment", point.series)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(tint)
            }
            .chartXScale(domain: range)
            .chartYScale(domain: valueDomain)
            .chartYAxis { sessionLeftYAxis(tint: tint) }
            .chartXAxis {
                timeAxis(
                    showsLabels: showsTimeLabels,
                    elapsedTimeOrigin: elapsedTimeOrigin,
                    showsSeconds: range.upperBound.timeIntervalSince(range.lowerBound) <= SessionChartViewport.minimumZoomDuration + 1
                )
            }
            .chartPlotStyle { plot in plot.clipped() }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity)
    }

    /// Recompute the value scale from points in the shared horizontal window, so
    /// pinching/zooming makes the variation currently on screen easier to read.
    private var visiblePoints: [SessionMetricPoint] {
        points.filter { range.contains($0.timestamp) }
    }

    private var valueDomain: ClosedRange<Double> {
        let values = visiblePoints.isEmpty ? points.map(\.value) : visiblePoints.map(\.value)
        guard let minimum = values.min(), let maximum = values.max() else { return 0...1 }
        let step = axisLabel == "bpm" ? 5.0 : (axisLabel == "°F" ? 2.0 : 1.0)
        let padding = max((maximum - minimum) * 0.15, step)
        let lower = floor((minimum - padding) / step) * step
        let upper = ceil((maximum + padding) / step) * step
        return lower...(upper > lower ? upper : lower + step)
    }
}

private func chartHeader(title: Text, unit: String, tint: Color) -> some View {
    HStack(alignment: .firstTextBaseline) {
        title
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
        Spacer(minLength: 8)
        Text(unit)
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 4)
    .frame(height: 16)
    .padding(.bottom, 8)
}

private func sessionLeftYAxis(tint: Color) -> some AxisContent {
    AxisMarks(position: .leading) { value in
        AxisGridLine()
        AxisTick().foregroundStyle(tint.opacity(0.7))
        AxisValueLabel {
            if let number = value.as(Double.self) {
                Text(number, format: .number.precision(.fractionLength(0...1)))
                    .frame(width: sessionChartAxisColumnWidth, alignment: .trailing)
                    .foregroundStyle(tint)
            }
        }
    }
}

private func timeAxis(showsLabels: Bool, elapsedTimeOrigin: Date?, showsSeconds: Bool) -> some AxisContent {
    AxisMarks(values: .automatic(desiredCount: showsSeconds ? 3 : 4)) { value in
        AxisGridLine()
        AxisTick()
        if showsLabels {
            AxisValueLabel {
                if let date = value.as(Date.self) {
                    if let elapsedTimeOrigin {
                        Text(Duration.seconds(date.timeIntervalSince(elapsedTimeOrigin)).formatted(.time(pattern: .minuteSecond)))
                    } else if showsSeconds {
                        Text(date, format: .dateTime.hour().minute().second())
                    } else {
                        Text(date, format: .dateTime.hour().minute())
                    }
                }
            }
        } else {
            AxisValueLabel().foregroundStyle(.clear)
        }
    }
}
