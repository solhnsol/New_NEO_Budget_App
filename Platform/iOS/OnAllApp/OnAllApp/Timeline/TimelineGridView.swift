import NEOBudgetCalendar
import SwiftUI

enum TimelineSelection: Identifiable {
    case block(EventBlock)
    case allDay(AllDayItem)
    case marker(TransactionMarkerItem)

    var id: String {
        switch self {
        case let .block(block): return "block-" + block.id.rawValue
        case let .allDay(item): return "allday-" + item.id.rawValue
        case let .marker(marker): return "marker-" + marker.transactionID.rawValue
        }
    }
}

/// The scrolling hour grid. Block geometry comes from `TimelineGeometry`; this view only draws it.
struct TimelineGridView: View {
    let timeline: DayTimeline
    let zone: DisplayTimeZone
    let isToday: Bool
    let onSelect: (TimelineSelection) -> Void

    var body: some View {
        let geometry = TimelineGeometry(totalMinutes: timeline.totalMinutes)
        let marks = geometry.hourMarks(dayStartUnixMilliseconds: timeline.dayStartUnixMilliseconds, zone: zone)
        ScrollViewReader { proxy in
            ScrollView {
                GeometryReader { size in
                    ZStack(alignment: .topLeading) {
                        ForEach(marks, id: \.elapsedMinute) { mark in
                            HourRow(mark: mark, geometry: geometry, width: size.size.width)
                        }
                        ForEach(timeline.blocks, id: \.id) { block in
                            let frame = geometry.blockFrame(block, totalWidth: size.size.width)
                            EventBlockView(block: block, zoneIdentifier: timeline.timeZoneIdentifier)
                                .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                                .offset(x: frame.minX, y: frame.minY)
                                .onTapGesture { onSelect(.block(block)) }
                        }
                        MarkerRail(timeline: timeline, geometry: geometry, width: size.size.width, onSelect: onSelect)
                        if isToday { NowLine(timeline: timeline, geometry: geometry, width: size.size.width) }
                    }
                }
                .frame(height: geometry.contentHeight)
                // Scroll anchors need real layout frames; `offset` does not move a view's frame.
                .background(alignment: .top) {
                    VStack(spacing: 0) {
                        ForEach(marks, id: \.elapsedMinute) { mark in
                            Color.clear.frame(height: 60 * geometry.pointsPerMinute).id("minute-\(mark.elapsedMinute)")
                        }
                    }
                }
            }
            .onAppear { scroll(proxy, geometry: geometry) }
            .onChange(of: timeline.day) { _, _ in scroll(proxy, geometry: geometry) }
        }
    }

    /// Starts near the first block, or the working day if the day is empty, so the screen does not open on 00:00.
    private func scroll(_ proxy: ScrollViewProxy, geometry: TimelineGeometry) {
        let target = max(0, (timeline.blocks.map(\.displayStartMinute).min() ?? 8 * 60) - 60)
        let hour = (target / 60) * 60
        proxy.scrollTo("minute-\(hour)", anchor: .top)
    }
}

private struct HourRow: View {
    let mark: TimelineGeometry.HourMark
    let geometry: TimelineGeometry
    let width: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            Text(Formatting.hourLabel(mark.wallHour))
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: geometry.gutterWidth - 6, alignment: .trailing)
                .offset(y: -7)
            Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 0.5)
                .padding(.leading, geometry.gutterWidth)
        }
        .frame(width: width, alignment: .topLeading)
        .offset(y: geometry.y(minute: mark.elapsedMinute))
        .accessibilityHidden(true)
    }
}

private struct NowLine: View {
    let timeline: DayTimeline
    let geometry: TimelineGeometry
    let width: CGFloat

    var body: some View {
        TimelineView(.everyMinute) { context in
            let nowMs = Int64(context.date.timeIntervalSince1970 * 1_000)
            let minute = Int((nowMs - timeline.dayStartUnixMilliseconds) / 60_000)
            if minute >= 0, minute <= timeline.totalMinutes {
                HStack(spacing: 0) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Rectangle().fill(.red).frame(height: 1)
                }
                .padding(.leading, geometry.gutterWidth - 4)
                .frame(width: width, alignment: .leading)
                .offset(y: geometry.y(minute: minute) - 4)
                .accessibilityHidden(true)
            }
        }
    }
}

private struct MarkerRail: View {
    let timeline: DayTimeline
    let geometry: TimelineGeometry
    let width: CGFloat
    let onSelect: (TimelineSelection) -> Void

    var body: some View {
        let positions = geometry.markerYPositions(minutes: timeline.markers.map(\.positionMinute))
        ForEach(Array(timeline.markers.enumerated()), id: \.element.transactionID) { index, marker in
            Button { onSelect(.marker(marker)) } label: {
                HStack(spacing: 3) {
                    Image(systemName: marker.flow == .refund ? "arrow.uturn.backward.circle.fill" : "creditcard.fill")
                        .font(.caption2)
                    Text(Formatting.money(marker.amount.minorUnits, currency: marker.amount.currency))
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .foregroundStyle(marker.flow == .refund ? Color.green : Color.orange)
                .background((marker.flow == .refund ? Color.green : Color.orange).opacity(0.14), in: Capsule())
                .overlay(Capsule().stroke(
                    marker.flow == .refund ? Color.green : Color.orange,
                    style: StrokeStyle(lineWidth: 1, dash: marker.timePrecision == .approximate ? [3] : [])
                ))
            }
            .buttonStyle(.plain)
            .frame(width: geometry.markerRailWidth - 4, alignment: .trailing)
            .offset(x: width - geometry.markerRailWidth, y: positions[index] - 10)
            .accessibilityLabel("지출 \(marker.title ?? "") \(Formatting.money(marker.amount.minorUnits, currency: marker.amount.currency))")
        }
    }
}
