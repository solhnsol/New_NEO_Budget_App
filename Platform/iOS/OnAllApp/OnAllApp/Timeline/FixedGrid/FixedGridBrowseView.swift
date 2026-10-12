import NEOBudgetCalendar
import SwiftUI

/// Browse on the fixed Temporal Grid, read-only (`BrowseAxisMode.fixedGrid`). The day is cut into N equal-height cells (hour boundaries) that fit the screen; what is drawn
/// on it is the product's own: `DayRenderPlan` (prepared once per day, placed on the grid's axis), the same event cards, titles, transaction lines and overflow cards,
/// and the same touch plan. What it does not have is the timeline editor: nothing here creates, moves or resizes, and the screen says so. The week strip, the day header
/// and the data (`AppModel`) are the existing ones; the day swipe is the existing one-day swipe, not the continuous date space.
struct FixedGridBrowseView: View {
    let strip: [StripDay]
    let today: LocalDate
    let zone: DisplayTimeZone
    let onSelect: (TimelineSelection) -> Void
    var onMoveDays: (Int) -> Void = { _ in }
    @Binding var swipeOffset: CGFloat
    @Binding var pendingDays: Int

    @State private var model = FixedGridBrowseModel()
    @State private var preparations = DayPlanPreparations()
    @State private var probe = ScrollProbe()
    @State private var settling = false
    @State private var choice: TouchChoice?
    @State private var noticeEmphasis = false
    @Environment(\.dynamicTypeSize) private var dynamicType

    private static let settleDuration = 0.22
    private static let edgePadding: CGFloat = 8
    private static let gutter: CGFloat = 60
    private static let trailing: CGFloat = 6

    private var visible: [DayTimeline?] { [strip[safe: 1]?.timeline, strip[safe: 2]?.timeline] }
    private var textScale: CGFloat { TextMeasurer.textScale() }

    var body: some View {
        VStack(spacing: 0) {
            DayHeaderStrip(strip: strip, today: today, swipeOffset: swipeOffset, onSelect: { onSelect(.allDay($0)) })
            Divider()
            EditingNotice(emphasised: noticeEmphasis)
            GeometryReader { outer in scrollView(size: outer.size) }
        }
        .confirmationDialog("무엇을 선택할까요?", isPresented: Binding(get: { choice != nil }, set: { if !$0 { choice = nil } }), titleVisibility: .visible, presenting: choice) { choice in
            ForEach(choice.options) { option in Button(option.label) { option.action() } }
            Button("취소", role: .cancel) {}
        }
    }

    private func columns(width: CGFloat) -> DayColumns {
        DayColumns(count: 2, gutterWidth: Self.gutter, trailingPadding: Self.trailing, totalWidth: width)
    }

    private func scrollView(size: CGSize) -> some View {
        let height = max(1, (size.height - 2 * Self.edgePadding).rounded(.down))
        let columns = columns(width: size.width)
        let environment = FixedGridEnvironment(
            viewportHeight: height, contentWidth: max(0, columns.dayLayoutWidth - Self.gutter - Self.trailing),
            textScale: textScale, contentSize: "\(dynamicType)"
        )
        let window = model.window(strip: strip, zone: zone, environment: environment)
        return ScrollView {
            if let window { grid(window: window, width: size.width, height: height, columns: columns) }
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: Drawing

    private func grid(window: FixedGridWindow, width: CGFloat, height: CGFloat, columns: DayColumns) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: width, height: height)
            FixedHourAxis(partition: window.partition, width: width, gutter: Self.gutter, scale: textScale)
            ZStack(alignment: .topLeading) {
                ForEach(strip, id: \.day) { entry in
                    let position = entry.day.daysSinceUnixEpoch - (strip[safe: 1]?.day.daysSinceUnixEpoch ?? entry.day.daysSinceUnixEpoch) + 1
                    if let timeline = entry.timeline {
                        dayContent(timeline, window: window, layoutWidth: columns.dayLayoutWidth)
                            .frame(width: columns.dayLayoutWidth, height: height, alignment: .topLeading)
                            .offset(x: columns.originX(of: position - 1) + swipeOffset - columns.gutterWidth)
                    }
                }
            }
            .frame(width: max(0, width - columns.gutterWidth), height: height, alignment: .topLeading)
            .clipped()
            .offset(x: columns.gutterWidth)
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .onTapGesture { location in handleTap(at: location, window: window, columns: columns) }
        .background { gestureHost(columns: columns) }
        .padding(.vertical, Self.edgePadding)
    }

    private func role(of timeline: DayTimeline) -> DayRole? {
        if visible[0]?.day == timeline.day { return .main }
        if visible[1]?.day == timeline.day { return .secondary }
        return nil
    }

    /// Where everything of a day goes, from the day's prepared data and the grid's axis. Drawing and touching both use it.
    private func plan(_ timeline: DayTimeline, window: FixedGridWindow, layoutWidth: CGFloat) -> DayRenderPlan {
        DayRenderPlan(
            prepared: preparations.prepared(timeline: timeline, role: role(of: timeline), layout: window.layout),
            geometry: model.axis(for: timeline.day, partition: window.partition, zone: zone), layoutWidth: layoutWidth, textScale: textScale,
            metrics: TextMeasurer.presentationMetrics(), titleWidth: { window.titleWidths[$0] ?? DayContentLayout.estimatedTitleWidth($0, extra: 14) }
        )
    }

    private func dayContent(_ timeline: DayTimeline, window: FixedGridWindow, layoutWidth width: CGFloat) -> some View {
        let plan = plan(timeline, window: window, layoutWidth: width)
        let axis = model.axis(for: timeline.day, partition: window.partition, zone: zone)
        let scale = textScale
        let overlayFrames = plan.lines.filter { $0.reveal > 0 }.map(\.frame) + plan.overflows.map(\.frame)
        let coveringFrames = plan.lines.map(\.frame) + plan.overflows.map(\.frame)
        return ZStack(alignment: .topLeading) {
            ForEach(plan.events, id: \.block.id) { item in
                FixedBlockCell(item: item, zoneIdentifier: timeline.timeZoneIdentifier, scale: scale, overlays: overlayFrames)
            }
            ForEach(plan.events, id: \.block.id) { item in
                if let header = item.header {
                    EventHeaderView(block: item.block, rect: header, zoneIdentifier: timeline.timeZoneIdentifier)
                } else if item.showsTitleInCard {
                    EventTitleLayer(
                        block: item.block, frame: item.frame, place: item.title, columnRight: axis.gutterWidth + axis.contentWidth(totalWidth: width),
                        scale: scale, zoneIdentifier: timeline.timeZoneIdentifier, presentation: item.presentation,
                        maxTitleWidth: item.titleMaxWidth, startFits: item.startTimeFits,
                        startIsCovered: coveringFrames.contains { $0.intersects(CGRect(x: item.frame.maxX - 48, y: item.frame.minY + 3, width: 48, height: 11)) }
                    )
                }
            }
            ForEach(plan.lines, id: \.id) { line in TransactionLineView(item: line, scale: scale, edge: axis.gutterWidth, overEvent: plan.events.contains { $0.frame.intersects(line.frame) }) }
            ForEach(plan.overflows, id: \.id) { overflow in OverflowCardView(item: overflow, scale: scale, edge: axis.gutterWidth, overEvent: plan.events.contains { $0.frame.intersects(overflow.frame) }) }
            if timeline.day == today { FixedNowLine(timeline: timeline, axis: axis, width: width) }
        }
    }

    // MARK: Touch

    /// One tap handler for everything of the days, decided by the plan that was drawn: a transaction line or an overflow is touched where it is drawn, an event on its card
    /// or its header (44 pt minimum, as in Browse), and where touch areas meet the person chooses.
    private func handleTap(at point: CGPoint, window: FixedGridWindow, columns: DayColumns) {
        let column = columns.column(atX: point.x)
        guard point.x >= columns.gutterWidth, let timeline = visible[column] else { return }
        let local = columns.localPoint(point, column: column)
        let plan = plan(timeline, window: window, layoutWidth: columns.dayLayoutWidth)
        switch plan.hit(at: local) {
        case .nothing: break
        case let .event(id): perform(.event(id), in: timeline, plan: plan)
        case let .line(id): perform(.line(id), in: timeline, plan: plan)
        case let .overflow(id): perform(.overflow(id), in: timeline, plan: plan)
        case let .choose(candidates):
            choice = TouchChoice(options: candidates.map { candidate in
                TouchChoice.Option(id: "\(candidate)", label: FixedGridTouch.label(of: candidate, in: timeline, plan: plan)) { perform(candidate, in: timeline, plan: plan) }
            })
        }
    }

    private func perform(_ candidate: DayRenderPlan.Candidate, in timeline: DayTimeline, plan: DayRenderPlan) {
        if let selection = FixedGridTouch.selection(for: candidate, in: timeline, plan: plan) { onSelect(selection) }
    }

    private func gestureHost(columns: DayColumns) -> some View {
        EditGestureHost(
            probe: probe,
            panEnabled: false,
            swipeEnabled: !settling,
            scrollCommit: nil,
            reveal: nil,
            // Editing is not offered here: a long press only draws attention to the notice that says so.
            longPress: { phase, _ in if phase == .began { emphasiseNotice() } },
            panStartsAt: { _ in false },
            pan: { _, _ in },
            swipe: { phase, translation, velocity in swipe(phase, translation, velocity, columnWidth: columns.columnWidth) }
        )
    }

    private func emphasiseNotice() {
        noticeEmphasis = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            noticeEmphasis = false
        }
    }

    /// The existing one-day swipe (`DaySwipe`): the strip of days follows the finger and comes to rest on one whole day.
    private func swipe(_ phase: EditGestureHost.Phase, _ translation: CGFloat, _ velocity: CGFloat, columnWidth: CGFloat) {
        switch phase {
        case .began:
            break
        case .moved:
            swipeOffset = DaySwipe.liveOffset(translation: translation, columnWidth: columnWidth)
            let pending = DaySwipe.daysToMove(translation: translation, velocity: 0, columnWidth: columnWidth)
            if pending != pendingDays {
                pendingDays = pending
                Haptics.snap()
            }
        case .ended:
            let days = DaySwipe.daysToMove(translation: translation, velocity: velocity, columnWidth: columnWidth)
            if days != pendingDays {
                pendingDays = days
                Haptics.snap()
            }
            settling = true
            withAnimation(.easeOut(duration: Self.settleDuration)) {
                swipeOffset = DaySwipe.settledOffset(days: days, columnWidth: columnWidth)
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(Self.settleDuration + 0.02))
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    if days != 0 { onMoveDays(days) }
                    swipeOffset = 0
                    pendingDays = 0
                    settling = false
                }
            }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// What a touch candidate opens, and what to call it in a choice. Pure of the view, so it is tested.
enum FixedGridTouch {
    static func selection(for candidate: DayRenderPlan.Candidate, in timeline: DayTimeline, plan: DayRenderPlan) -> TimelineSelection? {
        switch candidate {
        case let .event(id):
            return timeline.blocks.first { $0.id == id }.map { .event($0) }
        case let .line(id):
            if let marker = timeline.markers.first(where: { $0.transactionID.rawValue == id }) { return .marker(marker) }
            if let item = timeline.blocks.flatMap(\.allocations).first(where: { $0.transactionID.rawValue == id }) {
                return .allocation(item, eventTitle: plan.lines.first { $0.id == id }?.linkedEventTitle)
            }
            return nil
        case let .overflow(id):
            return plan.overflows.first { $0.id == id }.map { .overflow(OverflowSelection($0, displays: DayRenderPlan.displays(of: timeline))) }
        }
    }

    static func label(of candidate: DayRenderPlan.Candidate, in timeline: DayTimeline, plan: DayRenderPlan) -> String {
        switch candidate {
        case let .event(id): return "일정 " + (timeline.blocks.first { $0.id == id }?.title ?? "")
        case let .line(id):
            let display = plan.lines.first { $0.id == id }?.display
            return "거래 " + (display?.title ?? "") + " " + (display.map { Formatting.money($0.amount.minorUnits, currency: $0.amount.currency) } ?? "")
        case let .overflow(id): return plan.overflows.first { $0.id == id }.map { OverflowCardView.summary($0) } ?? "거래 묶음"
        }
    }
}

// MARK: Pieces

/// The line that says what this view does not do.
private struct EditingNotice: View {
    let emphasised: Bool

    var body: some View {
        Label(BrowseAxisMode.editingNotice, systemImage: "lock.fill")
            .font(.caption2)
            .lineLimit(3)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .foregroundStyle(emphasised ? Color.primary : Color.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(emphasised ? Color.orange.opacity(0.25) : Color.secondary.opacity(0.08))
            .animation(.easeInOut(duration: 0.2), value: emphasised)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(BrowseAxisMode.editingNotice)
    }
}

/// One event card. A tap is the grid's single tap handler's (the same plan decides what is touched), so the card carries none; VoiceOver's default action opens it.
private struct FixedBlockCell: View {
    let item: DayRenderPlan.EventItem
    let zoneIdentifier: String
    let scale: CGFloat
    var overlays: [CGRect] = []

    var body: some View {
        let frame = item.drawnFrame
        EventBlockView(
            block: item.block, height: frame.height, titleOffset: item.title.dy, rows: item.insideRows,
            presentation: item.presentation, scale: scale, hasHeader: item.header != nil, zoneIdentifier: zoneIdentifier,
            endIsCovered: overlays.contains { $0.intersects(CGRect(x: frame.maxX - 48, y: frame.maxY - 16, width: 48, height: 16)) },
            startIsCovered: overlays.contains { $0.intersects(CGRect(x: frame.maxX - 48, y: frame.minY + 3, width: 48, height: 11)) },
            anchors: item.insideAnchors.map { $0 - frame.minY }
        )
        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
        .offset(x: frame.minX, y: frame.minY)
    }
}

/// The hour axis of the fixed grid: a line at every cell boundary across the days, and the whole hours on the gutter as `HourAxis` decides (only as many as the room
/// leaves between them). Hours are wall-clock hours.
private struct FixedHourAxis: View {
    let partition: TemporalGridPartition
    let width: CGFloat
    let gutter: CGFloat
    let scale: CGFloat

    var body: some View {
        let metrics = HourAxis.Metrics(textScale: scale)
        let states = HourAxis.layout(partition: partition, metrics: metrics)
        ZStack(alignment: .topLeading) {
            ForEach(0..<partition.slotCount, id: \.self) { slot in
                Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: max(0, width - gutter), height: 0.5)
                    .offset(x: gutter, y: partition.top(ofSlot: slot))
            }
            ForEach(states, id: \.hour) { state in
                if state.labelOpacity > 0.003 {
                    Text(Formatting.hourLabel(state.hour % 24))
                        .font(.system(size: metrics.labelFontSize).monospacedDigit()).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.5)
                        .frame(width: gutter - 6, height: metrics.labelHeight, alignment: .trailing)
                        .opacity(state.labelOpacity)
                        .offset(y: state.labelCentre - metrics.labelHeight / 2)
                }
            }
        }
        .frame(width: width, height: partition.totalHeight, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}

private struct FixedNowLine: View {
    let timeline: DayTimeline
    let axis: ElapsedMinuteAxisMapping
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
                .padding(.leading, axis.gutterWidth - 4)
                .frame(width: width, alignment: .leading)
                .offset(y: axis.y(minute: minute) - 4)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            }
        }
    }
}
