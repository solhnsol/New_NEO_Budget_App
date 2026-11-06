import NEOBudgetCalendar
import NEOBudgetCore
import SwiftUI

#if DEBUG
/// `-render-gallery`: one synthetic event drawn at a run of heights, side by side, through the same plan and views the timeline uses, so
/// the card ↔ line change, and the order things fade in, can be looked at height by height. Synthetic data only.
struct RenderGallery: View {
    private static let heights: [CGFloat] = [1.5, 3, 5, 8, 12, 16, 19, 22, 26, 30, 36, 42, 50, 62, 80, 110]
    @State private var scale = TextMeasurer.textScale()

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(120), spacing: 6, alignment: .top), count: 3), alignment: .leading, spacing: 10) {
                ForEach(Self.heights, id: \.self) { height in
                    VStack(spacing: 4) {
                        Text("\(height.formatted())pt").font(.system(size: 9)).monospacedDigit()
                        Text(level(height)).font(.system(size: 9, weight: .bold))
                        Cell(height: height, count: 3, scale: scale)
                    }
                }
            }
            .padding(12)
        }
    }

    private func level(_ height: CGFloat) -> String { EventPresentation.make(height: height, insideCount: 3, metrics: TextMeasurer.presentationMetrics()).level.name }

    private struct Cell: View {
        let height: CGFloat
        let count: Int
        let scale: CGFloat

        var body: some View {
            let fixture = Fixture.make(height: height, count: count)
            let plan = fixture.plan
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.secondary.opacity(0.08)).frame(width: 120, height: 120)
                if let item = plan.events.first {
                    EventBlockView(
                        block: item.block, height: item.drawnFrame.height, titleOffset: item.title.dy, rows: item.insideRows,
                        presentation: item.presentation, scale: scale, zoneIdentifier: "Asia/Seoul",
                        anchors: item.insideAnchors.map { $0 - item.frame.minY }
                    )
                    .frame(width: 110, height: item.drawnFrame.height).offset(x: 5, y: item.drawnFrame.minY - item.frame.minY + 5)
                    if item.showsTitleInCard {
                        EventTitleLayer(
                            block: item.block, frame: CGRect(x: 5, y: 5, width: 110, height: item.frame.height), place: item.title, columnRight: 115,
                            scale: scale, zoneIdentifier: "Asia/Seoul", presentation: item.presentation, startFits: true
                        )
                    }
                }
            }
            .frame(width: 120, height: 120, alignment: .topLeading)
        }
    }

    private enum Fixture {
        static func make(height: CGFloat, count: Int) -> (plan: DayRenderPlan, timeline: DayTimeline) {
            let zone = try! DisplayTimeZone(identifier: "Asia/Seoul")
            let day = try! LocalDate(year: 2027, month: 3, day: 10)
            let calendar = CalendarID(rawValue: "c")
            let range = try! TimedRange(startUnixMilliseconds: zone.instant(of: day, minuteOfDay: 600), endUnixMilliseconds: zone.instant(of: day, minuteOfDay: 660))
            let event = CalendarEvent(id: CalendarEventID(rawValue: "e0"), calendarID: calendar, title: "합성 일정", time: .timed(range), revisionToken: "r")
            let provenance = AssignmentProvenance.user(at: 1, evidenceVersion: nil)
            let activityID = ActivityID(rawValue: "A0")
            var changes: [LifeChange] = [.createActivity(Activity.materialized(from: event, id: activityID, at: 1))]
            var markers: [TransactionMarker] = []
            for index in 0..<count {
                let id = "t\(index)"
                let amount = try! Money(minorUnits: Int64(4_500 + index * 1_000), currency: "KRW")
                markers.append(TransactionMarker(
                    id: LedgerEntryID(rawValue: id), occurredAtUnixMilliseconds: zone.instant(of: day, minuteOfDay: 610 + index * 15),
                    amount: amount, flow: .spend, title: "상점 \(index + 1)"
                ))
                changes.append(.upsertAllocation(
                    TransactionAllocation(
                        id: AllocationID(rawValue: "alloc-\(id)"), transactionID: LedgerEntryID(rawValue: id), activityID: activityID,
                        amount: try! AmountEntry(currency: "KRW", knowledge: .exact(amount.minorUnits), provenance: provenance),
                        provenance: provenance, createdAtUnixMilliseconds: 1),
                    transactionTotal: amount, flow: .spend))
            }
            let timeline = DayTimelineBuilder.build(DayTimelineInput(
                day: day, timeZone: zone, calendars: [CalendarDescriptor(id: calendar, title: "약속")],
                events: [event], life: try! LifeState.empty.applying(changes), transactions: markers
            ))
            let geometry = TimelineGeometry(totalMinutes: 1440, pointsPerMinute: height / 60)
            let plan = DayRenderPlan(
                timeline: timeline, role: nil, layout: nil, geometry: geometry, layoutWidth: 200, textScale: TextMeasurer.textScale(),
                metrics: TextMeasurer.presentationMetrics(), titleWidth: { TextMeasurer.titleWidth($0) }
            )
            return (plan, timeline)
        }
    }
}
#endif
