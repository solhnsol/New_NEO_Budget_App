import Combine
import NEOBudgetCalendar
import NEOBudgetCore
import SwiftUI
import UIKit

/// Browse on the fixed Temporal Grid (`BrowseAxisMode.fixedGrid`). The day is cut into N equal-height cells (hour boundaries) that fit the screen at 1×; what is drawn on
/// it is the product's own: `DayRenderPlan` (prepared once per day and layout, placed on the grid's axis), the same event cards, titles, transaction lines and overflow cards,
/// and the same touch plan. Two things move it:
///
/// - **The days**: a finger drags the day line directly (`DayMoveModel`, `DayAxisGeometry`, `ContinuousDayAxis`: every column and the hour axis use the one time partition
///   that is the blend of the two windows around the position). Letting go flicks to a day or back (the model's spring); a finger that comes down on a moving day line takes it
///   over; the next flick may begin before the last has settled. `AppModel.selectedDay` follows when the line comes to rest, or when a new touch takes over a move that has
///   passed a day.
/// - **The zoom**: a pinch 1×…8× about the fingers' centre (`PinchZoomScrollView`), scrolling and its inertia with it. While the days move on a zoomed view the time at the
///   middle of the screen stays where it is (`AnchorState`).
///
/// Nothing here plans on a gesture frame: the partitions of the windows around the selected day are planned off the main thread when the day, the data or the room change
/// (`FixedGridBrowseModel.warm`), the engine's decisions are made per window and rested zoom, and a frame only blends, scales and places. Editing is an edit session on one event
/// (`FixedGridEditInteraction`): a tap on an event opens one; a long press on empty grid picks up a new event that follows the finger (`FixedGridCreatePlacement`) and opens one
/// on it when the finger lifts.
struct FixedGridBrowseView: View {
    let model: AppModel
    let today: LocalDate
    let zone: DisplayTimeZone
    let onSelect: (TimelineSelection) -> Void
    /// `AppModel.selectedDay` is to move by this many days (the screen moves it with the days already read and reads what the new window is missing).
    var onMoveDays: (Int) -> Void = { _ in }
    @Binding var pendingDays: Int

    @State private var move: DayMoveModel
    @State private var position: Double
    @State private var pinch = PinchZoomModel()
    @State private var planner = FixedGridBrowseModel()
    @State private var preparations = DayPlanPreparations(limit: 16)
    @State private var anchorState: AnchorState
    @State private var dragStart: Double?
    @State private var ticking = false
    @State private var caughtTarget: Int?
    /// The days are running to a day something else picked (the week strip, the header, "오늘"): where from and to. The time is blended between these two only.
    @State private var flight: (from: Int, to: Int)?
    /// The selected day this screen moved itself to (a touch taking over a move, a move coming to rest), so the change is not taken for one from outside.
    @State private var ownEpoch: Int?
    @State private var lastNeeded: ClosedRange<Int>?
    @State private var choice: TouchChoice?
    /// A new event carried by the finger after a long press on empty grid (until it lifts).
    @State private var placing: FixedGridCreatePlacement?
    /// A transaction carried by the finger after a long press on its line, to be put down on an event (until it lifts).
    @State private var carrying: FixedGridTransactionCarry?
    /// Where the finger carrying a new event is, and how far the card's left edge is from it: the card is in the hand, wherever the finger is; only the
    /// outline where it would be put down keeps to the 15-minute lines.
    @State private var carriedFinger: CGPoint?
    @State private var carriedGrabX: CGFloat = 0
    /// What `placing` carries is the edited event itself (long pressed, in browse or while editing), not a new one: put down, the draft moves to it.
    @State private var lifted = false
    /// The edit session (`FixedGridEditInteraction`; a long press on an editable event opens one). The screen sends it the grid's touches and the selected
    /// day, and carries out its grid commands (freeze, retarget, unfreeze); the rest go to the parts that edit (`editor`).
    @State private var edit = FixedGridEditRouter()
    /// The parts that edit: the draft, the precision bubble's state, the save (`FixedGridEditor`). Made when the screen first appears.
    @State private var editor: FixedGridEditor?
    /// Keeps the precision bubble next to its handle through scrolls and pinches (only the bubble is redrawn).
    @StateObject private var bubbleTracker = PrecisionAnchorTracker()
    /// The edit bar's height as drawn (the bubble keeps above it).
    @State private var editBarHeight: CGFloat = 0
    /// How far the keyboard reaches up over the grid (the edit bar rides on it), and where the grid is on screen.
    @State private var keyboardOverlap: CGFloat = 0
    /// The scroll offset before the session began (the scroll goes back to it when the session ends, with the keyboard), how long the keyboard takes to
    /// move, and the pending release of the bar's room once the keyboard is gone.
    @State private var preEditOffset: CGFloat?
    @State private var keyboardDuration: TimeInterval = 0.25
    @State private var releaseInset: Task<Void, Never>?
    /// The scroll is on its way back to where the session began: the anchor that holds the time at the middle through a re-plan must not pull it away.
    @State private var restoringScroll = false
    @State private var gridFrame: CGRect = .zero
    @State private var planningVersion = 0
    @State private var restedZoomKey = 4
    @State private var room = Room()
    /// The room as the screen last heard of it (the `Room` above is for code outside a frame; these make planning ahead start when the room becomes known or changes).
    @State private var knownViewport: CGFloat = 0
    @State private var knownWidth: CGFloat = 0
    /// Bumped while a window's partition eases to a new plan (a day arrived), so the frames of the easing are drawn.
    @State private var axisTick = 0
    @Environment(\.dynamicTypeSize) private var dynamicType

    /// The width the grid has, for the parts that run outside a frame (the spring's ticker, the planning ahead), and what runs between frames.
    final class Room {
        var width: CGFloat = 0
        var easing = false
        /// Reads of a day on screen that failed and were tried again.
        var retries: [LocalDate: Int] = [:]
        var probePath: String?
        /// The week strip's pending day as last shown (kept here too, for the experiment that does not show it).
        var pending = 0
        var haptic: UISelectionFeedbackGenerator?
        /// Frames that drew a day from two decisions, frames where those two differed, and the most things crossfaded in one (DEBUG reports).
        var blendFrames = 0, differingFrames = 0, crossfadedMost = 0
        /// What the DEBUG edit probe saw: handle taps, handle drags and their steps, long presses meaning "create" on empty grid, and the day position when a
        /// handle drag began and ended (a drag from a handle must not move the days).
        var handleTaps = 0, handleDrags = 0, handleSteps = 0, createPresses = 0
        /// Transactions picked up from their line, and put down on an event (linked).
        var carryPickUps = 0, carryLinks = 0
        var dragPositions: [Double] = []
        var probeWrite: Task<Void, Never>?
        /// The planner's freeze for the open session, and the session's id it belongs to.
        var frozen: (session: Int, freeze: Int)?
        /// The chosen handle's centre at 1× (the partition is frozen while editing, so at a zoom it is this with y times the zoom), for the bubble.
        var bubbleAnchor: CGPoint?
        /// How far (points) the dragged handle's centre was below the finger when the drag began: the edge follows the finger at that distance.
        var grabOffset: CGFloat = 0
        /// After a save: the edited edge kept at its height while the axis eases from the frozen partition (`FixedGridUnfreezeAnchor`); `nil` otherwise.
        var unfreezeAnchor: FixedGridUnfreezeAnchor?
        /// DEBUG edit probe: how far (points) the edge was from its height when the easing ended.
        var anchorDrift: CGFloat?
    }

    /// What each step of a move cost and how far apart the steps were, in milliseconds (reported by the DEBUG scripts).
    final class Costs {
        var apply: [Double] = []
        var intervals: [Double] = []
        var last: CFAbsoluteTime = 0
        func record(apply ms: Double) {
            apply.append(ms)
            let now = CFAbsoluteTimeGetCurrent()
            if last > 0, now - last < 0.2 { intervals.append((now - last) * 1000) }
            last = now
        }
        func summary(_ values: [Double]) -> String {
            guard !values.isEmpty else { return "—" }
            let sorted = values.sorted()
            return String(format: "mean %.3f / p50 %.3f / p99 %.3f / max %.3f ms (n=%d)", values.reduce(0, +) / Double(values.count), sorted[sorted.count / 2], sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))], sorted.last ?? 0, values.count)
        }
    }
    @State private var costs = Costs()

    /// The display link's own interval, for the DEBUG scripts: how long the main thread kept each frame waiting.
    @MainActor final class FrameMeter: NSObject {
        var intervals: [Double] = []
        private var last: CFTimeInterval = 0
        private var link: CADisplayLink?
        func start() { intervals = []; last = 0; let link = CADisplayLink(target: self, selector: #selector(tick(_:))); link.add(to: .main, forMode: .common); self.link = link }
        func stop() { link?.invalidate(); link = nil }
        @objc private func tick(_ link: CADisplayLink) { if last > 0 { intervals.append((link.timestamp - last) * 1000) }; last = link.timestamp }
    }

    /// How far the screen's own top bar reaches below the screen's top edge: the grid may show that much above its own header too.
    let chromeInset: CGFloat

    private static let gutter: CGFloat = 62
    private static let trailing: CGFloat = 6
    private static let visibleColumns = 2

    init(model: AppModel, today: LocalDate, zone: DisplayTimeZone, chromeInset: CGFloat = 0, onSelect: @escaping (TimelineSelection) -> Void, onMoveDays: @escaping (Int) -> Void, pendingDays: Binding<Int>) {
        self.model = model
        self.today = today
        self.zone = zone
        self.chromeInset = chromeInset
        self.onSelect = onSelect
        self.onMoveDays = onMoveDays
        _pendingDays = pendingDays
        let selected = model.selectedDay.daysSinceUnixEpoch
        _move = State(initialValue: DayMoveModel(day: selected, bounds: FixedGridMove.bounds(around: selected), maximumHop: DayPrefetchPolicy.browse.maximumHop))
        _position = State(initialValue: Double(selected))
        _anchorState = State(initialValue: AnchorState(position: Double(selected)))
    }

    private var selectedEpoch: Int { model.selectedDay.daysSinceUnixEpoch }
    private var textScale: CGFloat { TextMeasurer.textScale() }

    private func geometry(width: CGFloat) -> DayAxisGeometry {
        DayAxisGeometry(dayWidth: (width - Self.gutter) / CGFloat(Self.visibleColumns), visibleColumns: Self.visibleColumns)
    }

    var body: some View {
        let probe = BrowseProbe.begin(.screenBody)
        defer { BrowseProbe.end(probe) }
        _ = (position, planningVersion, model.dataRevision, axisTick)   // this screen re-evaluates when the days move, planning ahead lands, the kept days change or the axis eases
        _ = (editor?.draft?.range, editor?.edge)                         // … and when the edited time or the chosen handle changes (the grid draws the draft card)
        _ = (placing, carriedFinger)                                     // … and while a new event is carried by the finger
        _ = carrying                                                     // … or a transaction
        return GeometryReader { outer in
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    headerStrip(width: outer.size.width)
                    Divider()
                }
                .background { TopBarBackground() }          // the grid is drawn under it (`topOverhang`), so what scrolled up shows through
                .zIndex(1)
                if ProbeExperiment.editProbe { EditProbeLine(text: editProbeText) }
                grid(width: outer.size.width)
            }
            .onAppear { room.width = outer.size.width; knownWidth = outer.size.width; pinch.topOverhang = DayHeaderStrip.height + 1 + chromeInset }
            .onChange(of: chromeInset) { _, inset in pinch.topOverhang = DayHeaderStrip.height + 1 + inset }
            .onChange(of: outer.size.width) { _, width in room.width = width; knownWidth = width }
        }
        .confirmationDialog("무엇을 선택할까요?", isPresented: Binding(get: { choice != nil }, set: { if !$0 { choice = nil } }), titleVisibility: .visible, presenting: choice) { choice in
            ForEach(choice.options) { option in Button(option.label) { option.action() } }
            Button("취소", role: .cancel) {}
        }
        .task {
            // The days around the selected one and the margin the cache keeps ahead (the screen read only the four it draws).
            let policy = DayPrefetchPolicy.browse
            await model.loadMissing(extra: policy.readAhead, policy: policy.cachePolicy, failsScreen: false)
        }
        .task { await runDebugScript() }
        .task { startProbeIfAsked() }
        .task { connectEditing() }
        .task(id: failedOnScreen) { await retryFailedOnScreen() }
        .task(id: WarmKey(selected: selectedEpoch, revision: model.dataRevision, version: planningVersion, zoomKey: restedZoomKey, viewport: knownViewport, text: "\(dynamicType)", width: knownWidth)) {
            await warmAhead()
        }
        .onReceive(pinch.$viewportHeight.removeDuplicates()) { knownViewport = $0 }
        .onReceive(pinch.$isInteracting.removeDuplicates().filter { !$0 }) { _ in
            restedZoomKey = planner.plannedZoomKey(current: pinch.zoom, settling: pinch.settlingZoom)
            writeProbeSoon()
        }
        .onChange(of: model.selectedDay) { _, _ in selectionChangedOutside() }
        .onChange(of: model.dataRevision) { _, _ in
            if let editor, let day = editor.target?.blockDay { editor.dataChanged(generation: model.dataGeneration, timelines: [model.cachedTimeline(for: day)].compactMap { $0 }) }
        }
        .onChange(of: BubbleKey(editor: editor)) { _, _ in followBubble() }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { keyboardChanged($0) }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { keyboardChanged($0) }
        .onChange(of: editBarHeight) { _, _ in keepChosenCardVisible() }
        .onChange(of: edit.session?.id) { _, _ in sessionChanged() }
        .onChange(of: edit.session?.target) { _, _ in keepChosenCardVisible() }
        .onChange(of: editor?.isRenaming) { _, _ in keepChosenCardVisible() }
        // The grid keeps its size under the keyboard: its partition is planned for the room it has, and a rename must not re-plan the day.
        .ignoresSafeArea(.keyboard)
    }

    /// What moves the precision bubble's handle: the session, the chosen edge, the edited range.
    private struct BubbleKey: Equatable {
        let session: Int?
        let edge: EditDraft.Edge?
        let range: TimedRange?
        @MainActor init(editor: FixedGridEditor?) { session = editor?.session; edge = editor?.edge; range = editor?.draft?.range }
    }

    private struct WarmKey: Equatable {
        let selected: Int
        let revision: Int
        let version: Int
        let zoomKey: Int
        let viewport: CGFloat
        let text: String
        let width: CGFloat
    }

    // MARK: Header

    /// The day names and all-day events follow the same position: the days around the one the position is in, slid by the fraction.
    private func headerStrip(width: CGFloat) -> some View {
        let first = Int(position.rounded(.down))
        let columnWidth = geometry(width: width).dayWidth
        let strip = (-1...2).map { offset -> StripDay in
            let day = LocalDate(daysSinceUnixEpoch: first + offset)
            return StripDay(day: day, timeline: model.cachedTimeline(for: day))
        }
        // While editing, a tap on the header is a tap outside the event (it opens nothing).
        return DayHeaderStrip(strip: strip, today: today, swipeOffset: -CGFloat(position - Double(first)) * columnWidth, onSelect: { item in
            if edit.state.editing != nil { edit.send(.tapOutside) } else { onSelect(.allDay(item)) }
        }, gutter: Self.gutter)
    }

    // MARK: Grid

    private func inputs(viewport: CGFloat, width: CGFloat) -> FixedGridBrowseModel.Inputs {
        let environment = FixedGridEnvironment(
            viewportHeight: viewport, contentWidth: max(0, geometry(width: width).dayWidth - Self.trailing), textScale: textScale, contentSize: "\(dynamicType)"
        )
        return FixedGridBrowseModel.Inputs(zone: zone, environment: environment, timelineFor: { model.cachedTimeline(for: $0) }, revision: model.dataRevision)
    }

    /// What one frame is drawn from: the shared partition at the position and zoom, which decision each day on screen is drawn from (`FixedGridColumns`), and
    /// those decisions (the windows around the position, at the zoom the plan is for).
    private struct Frame {
        let shown: TemporalGridPartition
        let columns: [FixedGridColumns.Column]
        let decisions: [Int: FixedGridBrowseModel.Decision]
        /// While the days are between two whole days: each window's own partition at the zoom (what its decision's cards are at rest), which what is written in the
        /// cards is read from; empty at rest and during an edit session (the shown partition is then the only one).
        let restPartitions: [Int: TemporalGridPartition]

        func decision(_ source: FixedGridColumns.Source) -> FixedGridBrowseModel.Decision {
            decisions[source.window] ?? FixedGridBrowseModel.Decision(layout: nil, titleWidths: [:])
        }
        func column(_ epoch: Int) -> FixedGridColumns.Column? { columns.first { $0.epoch == epoch } }

        /// What the cards of a day are written from while the days move: the partition of the decision the day is drawn from, at rest; for the day passing from one
        /// decision to the next, the two blended by the weight, so both plans of the day read the same heights (they stay one card, with no crossfade of what is
        /// written in it) and the rows come and go with the height they change through.
        func presentationPartition(_ column: FixedGridColumns.Column) -> TemporalGridPartition? {
            guard let from = restPartitions[column.from.window] else { return nil }
            guard let to = column.to, let end = restPartitions[to.window] else { return from }
            return TemporalGridPartition.interpolated(from: from, to: end, progress: column.weight) ?? from
        }
    }

    private func frame(zoom: CGFloat, viewport: CGFloat, width: CGFloat) -> Frame {
        let inputs = inputs(viewport: viewport, width: width)
        let bounds = move.bounds
        let shown = planner.shared(position: position, bounds: bounds, inputs: inputs, flight: flight).zoomed(viewportHeight: viewport, zoomScale: zoom)
        let days = geometry(width: width).renderedDays(at: position)
        let columns = ProbeExperiment.legacyColumns
            ? FixedGridColumns.legacyColumns(days: days, position: position, bounds: bounds)
            : FixedGridColumns.columns(days: days, position: position, bounds: bounds)
        let zoomKey = planner.plannedZoomKey(current: zoom, settling: pinch.settlingZoom)
        // While an ended pinch eases back inside 1 … 8× its frames are not decided: they are drawn with the decision made for where it comes to rest (or the
        // nearest one made, until that one is) — the planning ahead makes it between frames.
        let easingBack = pinch.settlingZoom != nil && !ProbeExperiment.legacyZoomKey
        var decisions: [Int: FixedGridBrowseModel.Decision] = [:]
        for window in FixedGridColumns.windows(of: columns) {
            decisions[window] = planner.decisionForDrawing(window: window, zoomKey: zoomKey, isInteracting: pinch.isInteracting || easingBack, inputs: inputs)
        }
        if planner.isEasing { easeAxis() }
        var rest: [Int: TemporalGridPartition] = [:]
        if abs(position - position.rounded()) > 0.0005, planner.frozen == nil {
            for window in decisions.keys where planner.thawing(window: window) == nil {
                if let planned = planner.plannedPartition(window: window, inputs: inputs) { rest[window] = planned.zoomed(viewportHeight: viewport, zoomScale: zoom) }
            }
        }
        return Frame(shown: shown, columns: columns, decisions: decisions, restPartitions: rest)
    }

    private func grid(width: CGFloat) -> some View {
        PinchZoomScrollView(model: pinch, onDateDrag: { handleDateDrag($0, width: width) }, gestures: gestureHooks()) { zoom, viewport, window in
            gridContent(width: width, zoom: zoom, viewport: viewport, window: window)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { gridFrame = $0 }
        .overlay(alignment: .topLeading) { loadingMarks(width: width) }
        // Over the scroll view, not in its content: the content's recognizers would take the bubble's touches.
        .overlay {
            TrackedPrecisionBubbleOverlay(
                input: editor?.bubbleInput, tracker: bubbleTracker, margins: EdgeInsets(top: 8, leading: 8, bottom: editBarHeight + 8, trailing: 8),
                onAction: { editor?.bubble($0) }
            )
        }
        .overlay(alignment: .bottom) { editBar }
        .confirmationDialog(
            "반복 일정이에요", isPresented: Binding(get: { editor?.scopeQuestion != nil }, set: { shown in if !shown { scopeDialogClosed() } }),
            titleVisibility: .visible, presenting: editor?.scopeQuestion
        ) { question in
            ForEach(question.options, id: \.self) { scope in Button(FixedGridEditor.label(for: scope)) { editor?.answer(scope) } }
            Button("취소", role: .cancel) { editor?.answer(nil) }
        } message: { _ in
            Text("바꾼 시간을 어디까지 적용할까요?")
        }
    }

    /// The dialog went away without a choice (a tap outside it): back to editing with the changes kept. A choice answers first, so this finds no question.
    private func scopeDialogClosed() {
        guard let id = editor?.scopeQuestion?.id else { return }
        Task { @MainActor in if editor?.scopeQuestion?.id == id { editor?.answer(nil) } }
    }

    private func sessionBar(_ editor: FixedGridEditor) -> some View {
        EditSessionBar(
            editor: editor, zone: zone, calendars: model.calendars, people: model.catalog.people.filter { !$0.isSelf }, isCommitting: edit.session?.committing == true,
            rename: { edit.send(.tapTitle) }, endRename: { edit.send(.endRename) },
            cancel: { edit.send(.cancel) }, confirm: { edit.send(.confirm) }
        )
    }

    /// Floating over the bottom of the grid (the grid itself runs down to the bottom edge and never changes size): the messages (above the bar, and on
    /// their own after a session) and the edit bar while a session is open. The bar is the same one while the title is renamed; it only rides up on the keyboard.
    private var editBar: some View {
        let open = edit.session != nil
        let hasContent = editor?.message != nil || open
        return VStack(spacing: 8) {
            if let message = editor?.message {
                EditMessageView(message: message)
                    .task(id: message.id) {
                        try? await Task.sleep(for: .seconds(message.isProblem ? 4 : 2.5))
                        editor?.dismissMessage(message.id)
                    }
                    .onTapGesture { editor?.dismissMessage(message.id) }
            }
            if let editor, open { sessionBar(editor) }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, hasContent ? 8 + keyboardOverlap : 0)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { editBarHeight = $0 }
        .animation(.easeOut(duration: 0.18), value: edit.session != nil)
        .animation(.easeOut(duration: 0.18), value: editor?.message)
        .animation(.easeOut(duration: 0.25), value: keyboardOverlap)
        .animation(.easeOut(duration: 0.18), value: editor?.isRenaming)
    }

    /// While a session is open the chosen card is kept in the part of the grid the edit bar (and the keyboard under it) leaves: the whole card with its
    /// handles when it fits, else its top; while renaming, its title. The scroll may go past the end of the day by the bar's height (`bottomInset`), so a
    /// card at the end of the day can come above the bar even at 1×.
    private func keepChosenCardVisible() {
        guard edit.session != nil else { return }                                      // the room is released by `sessionChanged`, once the keyboard is gone
        pinch.bottomInset = editBarHeight
        guard edit.session?.committing != true, let card = gestureMode.target?.frame, !card.isNull else { return }
        let viewport = pinch.viewportHeight, offset = pinch.currentOffset?() ?? 0
        let top: CGFloat = 8, bottom = viewport - editBarHeight - 8
        guard viewport > 1, bottom - top > 44 else { return }
        let margin = EditHit.handleRadius
        let shown = editor?.isRenaming == true ? min(card.height, 44) : card.height
        let span = (card.minY - margin - offset)...(card.minY + shown + margin - offset)
        guard span.lowerBound < top || span.upperBound > bottom else { return }
        var target = offset
        if span.upperBound - span.lowerBound > bottom - top || span.lowerBound < top { target += span.lowerBound - top }
        else { target += span.upperBound - bottom }
        let range = pinch.offsetRange(zoom: pinch.zoom)
        target = min(max(target, range.lowerBound), range.upperBound)
        if abs(target - offset) > 0.5 { pinch.scrollTo?(target, 0.32) }
    }

    /// A session began: the offset it began at is kept. It ended (done or cancelled): the scroll goes back to that offset in the time the keyboard takes to
    /// leave, and the bar's room (`bottomInset`) is kept until the keyboard is gone, then let go without moving the content.
    private func sessionChanged() {
        if edit.session != nil {
            releaseInset?.cancel()
            restoringScroll = false
            if preEditOffset == nil { preEditOffset = pinch.currentOffset?() }
            keepChosenCardVisible()
            return
        }
        let duration = keyboardOverlap > 0 ? keyboardDuration : 0.25
        if let back = preEditOffset {
            let range = PinchZoomMath.offsetRange(zoom: pinch.zoom, viewport: pinch.viewportHeight)
            let target = min(max(back, range.lowerBound), range.upperBound)
            if room.unfreezeAnchor == nil, let now = pinch.currentOffset?(), abs(now - target) > 0.5 { restoringScroll = true; pinch.scrollTo?(target, duration) }
        }
        preEditOffset = nil
        releaseInset?.cancel()
        releaseInset = Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration + 0.1))
            restoringScroll = false
            guard !Task.isCancelled, edit.session == nil else { return }
            pinch.bottomInset = 0
        }
    }

    /// How much of the grid the keyboard covers (the grid itself keeps its size: its partition is planned for the room it has).
    private func keyboardChanged(_ note: Notification) {
        let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
        let hiding = note.name == UIResponder.keyboardWillHideNotification
        keyboardOverlap = hiding ? 0 : max(0, gridFrame.maxY - frame.minY)
        if let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval, duration > 0 { keyboardDuration = duration }
    }

    /// A day on screen that is not kept yet says whether it is being read or could not be read (a kept day with nothing on it is drawn as the empty day it is).
    private func loadingMarks(width: CGFloat) -> some View {
        let geometry = geometry(width: width)
        let missing = geometry.renderedDays(at: position).filter { model.cachedTimeline(for: LocalDate(daysSinceUnixEpoch: $0)) == nil }
        return ZStack(alignment: .topLeading) {
            ForEach(Array(missing), id: \.self) { epoch in
                DayLoadingMark(state: model.loadState(for: LocalDate(daysSinceUnixEpoch: epoch)))
                    .frame(width: geometry.dayWidth)
                    .offset(x: geometry.x(ofDay: Double(epoch), at: position) - Self.gutter, y: 12)
            }
        }
        .frame(width: max(0, width - Self.gutter), height: 56, alignment: .topLeading)
        .clipped()
        .offset(x: Self.gutter)
        .allowsHitTesting(false)
    }

    /// The days on screen whose read failed (tried again a few times, a second apart).
    private var failedOnScreen: [LocalDate] {
        [model.selectedDay, model.selectedDay.adding(days: 1)].filter { model.loadState(for: $0) == .failed }
    }

    private func retryFailedOnScreen() async {
        let days = failedOnScreen.filter { (room.retries[$0] ?? 0) < 3 }
        guard !days.isEmpty else { return }
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled, move.phase == .resting else { return }
        for day in days { room.retries[day, default: 0] += 1 }
        await model.prefetch(forPosition: Double(selectedEpoch))
    }

    private func gridContent(width: CGFloat, zoom: CGFloat, viewport: CGFloat, window: ClosedRange<CGFloat>) -> AnyView {
        guard viewport > 1, width > Self.gutter else { return AnyView(Color.clear.frame(width: max(width, 1), height: 1)) }
        let frame = frame(zoom: zoom, viewport: viewport, width: width)
        let geometry = geometry(width: width)
        let layoutWidth = Self.gutter + geometry.dayWidth
        let height = frame.shown.totalHeight
        let days = geometry.renderedDays(at: position).filter { model.cachedTimeline(for: LocalDate(daysSinceUnixEpoch: $0)) != nil }
        return AnyView(
            ZStack(alignment: .topLeading) {
                Color.clear.frame(width: width, height: height)
                FixedHourAxis(partition: frame.shown, width: width, gutter: Self.gutter, scale: textScale)
                ZStack(alignment: .topLeading) {
                    ForEach(Array(days), id: \.self) { epoch in
                        if let timeline = model.cachedTimeline(for: LocalDate(daysSinceUnixEpoch: epoch)), let column = frame.column(epoch) {
                            dayColumn(timeline, column: column, frame: frame, layoutWidth: layoutWidth, window: window)
                                .frame(width: layoutWidth, height: height, alignment: .topLeading)
                                .overlay(alignment: .topLeading) {
                                    // The rule between this day's column and the one before it, under the header's.
                                    Rectangle().fill(Theme.divider).frame(width: 0.5, height: height).offset(x: Self.gutter).allowsHitTesting(false)
                                }
                                .offset(x: geometry.x(ofDay: Double(epoch), at: position) - Self.gutter)
                        }
                    }
                }
                .frame(width: max(0, width - Self.gutter), height: height, alignment: .topLeading)
                .clipped()
                .offset(x: Self.gutter)
            }
            .frame(width: width, height: height, alignment: .topLeading)
            .overlay(alignment: .topLeading) { editHandles() }
            .overlay(alignment: .topLeading) { draggedEdgeMark() }
            .overlay(alignment: .topLeading) { placementPreview(partition: frame.shown) }
            .overlay(alignment: .topLeading) { carryPreview() }
        )
    }

    /// Where everything of a day goes, from the day's prepared data under one decision and the shared axis. Drawing and touching both use it.
    private func plan(_ timeline: DayTimeline, column: FixedGridColumns.Column, source: FixedGridColumns.Source, frame: Frame, layoutWidth: CGFloat, decision: FixedGridBrowseModel.Decision? = nil) -> DayRenderPlan {
        planner.renderPlan(
            timeline, source: source, decision: decision ?? frame.decision(source), partition: frame.shown, zone: zone, layoutWidth: layoutWidth, textScale: textScale,
            metrics: TextMeasurer.presentationMetrics(), preparations: preparations,
            presentationPartition: decision == nil ? frame.presentationPartition(column) : nil
        )
    }

    /// One day: from its one decision, or, for the day passing from one window's decision to the next, what both draw the same way once and what differs
    /// from both, faded by the position.
    @ViewBuilder
    private func dayColumn(_ timeline: DayTimeline, column: FixedGridColumns.Column, frame: Frame, layoutWidth: CGFloat, window: ClosedRange<CGFloat>) -> some View {
        let leaving = plan(timeline, column: column, source: column.from, frame: frame, layoutWidth: layoutWidth)
        if let to = column.to {
            let arriving = plan(timeline, column: column, source: to, frame: frame, layoutWidth: layoutWidth)
            let blend = BrowseProbe.measure(.blend) { FixedGridColumns.blend(leaving, arriving) }
            let _ = countBlend(blend)
            let w = column.weight
            ZStack(alignment: .topLeading) {
                dayContent(timeline, plan: leaving, frame: frame, layoutWidth: layoutWidth, window: window, drawsNow: false) { blend.leaving.contains($0) ? 1 - w : 0 }
                dayContent(timeline, plan: arriving, frame: frame, layoutWidth: layoutWidth, window: window, drawsNow: true) { blend.arriving.contains($0) ? w : 1 }
            }
        } else if let thaw = planner.thawing(window: column.from.window) {
            // An edit session has just ended: the decisions it drew with pass to the current ones over the axis's easing, the same way.
            let during = plan(timeline, column: column, source: column.from, frame: frame, layoutWidth: layoutWidth, decision: thaw.decision)
            let blend = FixedGridColumns.blend(during, leaving)
            let w = thaw.weight
            ZStack(alignment: .topLeading) {
                dayContent(timeline, plan: during, frame: frame, layoutWidth: layoutWidth, window: window, drawsNow: false) { blend.leaving.contains($0) ? 1 - w : 0 }
                dayContent(timeline, plan: leaving, frame: frame, layoutWidth: layoutWidth, window: window, drawsNow: true) { blend.arriving.contains($0) ? w : 1 }
            }
        } else {
            dayContent(timeline, plan: leaving, frame: frame, layoutWidth: layoutWidth, window: window, drawsNow: true) { _ in 1 }
        }
    }

    private func countBlend(_ blend: FixedGridColumns.Blend) {
        room.blendFrames += 1
        let count = blend.leaving.count + blend.arriving.count
        if count > 0 { room.differingFrames += 1; room.crossfadedMost = max(room.crossfadedMost, count) }
    }

    /// `opacity`: how much of each thing to draw (0: not drawn).
    private func dayContent(
        _ timeline: DayTimeline, plan: DayRenderPlan, frame: Frame, layoutWidth width: CGFloat, window: ClosedRange<CGFloat>, drawsNow: Bool,
        opacity: @escaping (FixedGridColumns.Item) -> Double
    ) -> some View {
        let axis = planner.axis(for: timeline.day, partition: frame.shown, zone: zone)
        let scale = textScale
        let overlayFrames = plan.lines.filter { $0.reveal > 0 }.map(\.frame) + plan.overflows.map(\.frame)
        let coveringFrames = plan.lines.map(\.frame) + plan.overflows.map(\.frame)
        // Only what reaches the built window (a viewport beyond the screen each side) is made into views; the plan above is for all of it.
        func reaches(_ rect: CGRect) -> Bool { rect.maxY >= window.lowerBound && rect.minY <= window.upperBound }
        // The event being edited, once its time differs: drawn faint where it is in the calendar; the draft card shows where it is going.
        let ghostKey = editedOriginal.flatMap { $0.blockDay == timeline.day ? $0.eventKey : nil }
        let ghosts = Set(plan.events.filter { $0.block.eventKey == ghostKey }.map(\.blendItem))
        let base = opacity
        let opacity: (FixedGridColumns.Item) -> Double = { ghosts.contains($0) ? base($0) * 0.3 : base($0) }
        let events = plan.events.filter { reaches($0.drawnFrame) && opacity($0.blendItem) > 0 }
        let lines = plan.lines.filter { reaches($0.frame) && opacity(.line($0.id)) > 0 }
        let overflows = plan.overflows.filter { reaches($0.frame) && opacity(.overflow($0.id)) > 0 }
        return ZStack(alignment: .topLeading) {
            ForEach(events, id: \.block.id) { item in
                FixedBlockCell(item: item, zoneIdentifier: timeline.timeZoneIdentifier, scale: scale, overlays: overlayFrames)
                    .opacity(opacity(item.blendItem))
            }
            ForEach(Array(events.enumerated()), id: \.element.block.id) { index, item in
                if let label = item.dotLabel {
                    EventDotLabel(block: item.block, label: label, presentation: item.presentation, scale: scale)
                        .opacity(opacity(item.blendItem))
                }
                if item.showsTitleInCard {
                    EventTitleLayer(
                        block: item.block, frame: item.frame, place: item.title, columnRight: axis.gutterWidth + axis.contentWidth(totalWidth: width),
                        scale: scale, zoneIdentifier: timeline.timeZoneIdentifier, presentation: item.presentation,
                        maxTitleWidth: item.titleMaxWidth, startFits: item.startTimeFits,
                        startIsCovered: coveringFrames.contains { $0.intersects(CGRect(x: item.frame.maxX - 48, y: item.frame.minY + 3, width: 48, height: 11)) },
                        rangeIsCovered: {
                            // The time range under the title is written above every card, so it gives way to a card in front of this one (drawn later) and to a transaction's chip.
                            let rect = CGRect(x: item.frame.minX, y: item.frame.minY + 17, width: min(item.frame.width, 110), height: 14)
                            return events[(index + 1)...].contains { $0.drawnFrame.intersects(rect) } || coveringFrames.contains { $0.intersects(rect) }
                        }()
                    )
                    .opacity(opacity(item.blendItem))
                }
            }
            // A linked transaction outside its event's time: the event's stripe runs on to it.
            ForEach(lines.filter { $0.tail != nil }, id: \.id) { line in
                if let tail = line.tail {
                    TransactionTailView(tail: tail, colorHex: line.linkColorHex, dotX: axis.gutterWidth + LeaderLayout.dotSize / 2).opacity(opacity(.line(line.id)))
                }
            }
            ForEach(lines, id: \.id) { line in
                TransactionLineView(item: line, scale: scale, edge: axis.gutterWidth, overEvent: plan.events.contains { $0.frame.intersects(line.frame) }).opacity(opacity(.line(line.id)))
            }
            ForEach(overflows, id: \.id) { overflow in
                OverflowCardView(item: overflow, scale: scale, edge: axis.gutterWidth, overEvent: plan.events.contains { $0.frame.intersects(overflow.frame) }).opacity(opacity(.overflow(overflow.id)))
            }
            if drawsNow, timeline.day == today { FixedNowLine(timeline: timeline, axis: axis, width: width) }
        }
    }

    // MARK: Touch

    /// What a point of the grid touches: the day, its plan as drawn (the decision a touch goes to), the point in the day's coordinates, and where the day's column
    /// begins in the grid's. The one hit test of the grid: touch-down ownership, taps and long presses all use it.
    private struct Touched {
        let epoch: Int
        let timeline: DayTimeline
        let plan: DayRenderPlan
        let local: CGPoint
        let columnX: CGFloat
        var hit: DayRenderPlan.Hit { plan.hit(at: local) }
    }

    private func touched(at point: CGPoint) -> Touched? {
        let width = room.width, viewport = pinch.viewportHeight
        guard viewport > 1, width > Self.gutter, point.x >= Self.gutter else { return nil }
        let geometry = geometry(width: width)
        let frame = frame(zoom: pinch.zoom, viewport: viewport, width: width)
        let epoch = Int((position + Double((point.x - Self.gutter) / geometry.dayWidth)).rounded(.down))
        guard let timeline = model.cachedTimeline(for: LocalDate(daysSinceUnixEpoch: epoch)), let column = frame.column(epoch) else { return nil }
        let columnX = geometry.x(ofDay: Double(epoch), at: position)
        let plan = plan(timeline, column: column, source: column.dominant, frame: frame, layoutWidth: Self.gutter + geometry.dayWidth)
        return Touched(epoch: epoch, timeline: timeline, plan: plan, local: CGPoint(x: point.x - columnX, y: point.y), columnX: columnX)
    }

    /// The grid's touches for the scroll view's recognizers (`FixedGridGestures` decides who owns each).
    private func gestureHooks() -> GridGestureHooks {
        GridGestureHooks(
            start: { point in FixedGridGestures.start(at: point, gutter: Self.gutter, mode: gestureMode) { touched(at: point)?.hit ?? .nothing } },
            mode: { gestureMode },
            tap: { point, start in handleTap(at: point, start: start) },
            longPress: { phase, point, start in handleLongPress(phase, at: point, start: start) },
            handlePan: { phase, point, hit in handleHandleDrag(phase, at: point, hit: hit) }
        )
    }

    /// The mode the grid is in now; while editing, the chosen card where it is drawn now (it follows the zoom; the days do not move in a session). A session
    /// whose card cannot be placed now (its block rebuilt by a reload and gone) is still editing, without handles: the days stay where the session froze them.
    private var gestureMode: FixedGridGestures.Mode { lifted ? .lifting : edit.state.gestureMode(place: place) }

    private func place(_ target: FixedGridEditInteraction.Target) -> FixedGridGestures.EditTarget? {
        let width = room.width, viewport = pinch.viewportHeight
        guard viewport > 1, width > Self.gutter else { return nil }
        let geometry = geometry(width: width)
        let frame = frame(zoom: pinch.zoom, viewport: viewport, width: width)
        if target.isDrawnFromDraft {
            // A new event, or one put down on another day, is in no plan there: its card takes the whole column, where the draft has it.
            let axis = planner.axis(for: target.day, partition: frame.shown, zone: zone)
            let segment = editor?.target == target ? editor?.draft?.segment(on: target.day) : nil
            return FixedGridGestures.EditTarget(
                epoch: target.epoch, blockID: target.blockID,
                frame: newCardFrame(day: target.day, startMinute: segment?.startMinute ?? target.startMinute, endMinute: segment?.endMinute ?? target.endMinute, axis: axis),
                canResizeStart: true, canResizeEnd: true
            )
        }
        guard let timeline = model.cachedTimeline(for: target.day), let column = frame.column(target.epoch) else { return nil }
        let plan = plan(timeline, column: column, source: column.dominant, frame: frame, layoutWidth: Self.gutter + geometry.dayWidth)
        // By the block, else by the calendar's key (a reload may rebuild the block ids).
        guard let item = plan.events.first(where: { $0.block.id == target.blockID }) ?? plan.events.first(where: { $0.block.eventKey == target.eventKey }) else { return nil }
        var card = item.frame.offsetBy(dx: geometry.x(ofDay: Double(target.epoch), at: position), dy: 0)
        // The card is where the draft has it (its handles too), on the frozen axis.
        if let editor, editor.target == target, let segment = editor.draft?.segment(on: target.day) {
            let axis = planner.axis(for: target.day, partition: frame.shown, zone: zone)
            let top = axis.y(minute: segment.startMinute)
            card = CGRect(x: card.minX, y: top, width: card.width, height: max(1, axis.y(endMinute: segment.endMinute) - top))
        }
        return FixedGridGestures.EditTarget(
            epoch: target.epoch, blockID: item.block.id, frame: card,
            canResizeStart: !item.block.continuesFromPreviousDay, canResizeEnd: !item.block.continuesToNextDay
        )
    }

    /// The event being edited once its time differs from the calendar's (its card is drawn faint; the draft card is drawn where it is going).
    private var editedOriginal: FixedGridEditInteraction.Target? {
        guard let editor, editor.isChanged || lifted else { return nil }
        return editor.target
    }

    /// The elapsed minute of `day` at a grid point's height, on the axis drawn now (the frozen one during a session).
    private func minute(atY y: CGFloat, day: LocalDate) -> Int? {
        let width = room.width, viewport = pinch.viewportHeight
        guard viewport > 1, width > Self.gutter else { return nil }
        return planner.axis(for: day, partition: frame(zoom: pinch.zoom, viewport: viewport, width: width).shown, zone: zone).minute(atY: y)
    }

    /// The target an event of a touched day makes, when it can be edited.
    private func editTarget(_ id: BlockID, in found: Touched) -> FixedGridEditInteraction.Target? {
        guard let block = found.timeline.blocks.first(where: { $0.id == id }), block.isEditable else { return nil }
        return FixedGridEditInteraction.Target(day: found.timeline.day, block: block)
    }

    private func handleTap(at point: CGPoint, start: FixedGridGestures.Start) {
        switch FixedGridGestures.tap(start: start, mode: gestureMode, daysAtRest: move.phase == .resting, point: point) {
        case .none: break
        case .select: select(at: point)
        case .title: edit.send(.tapTitle)
        case let .handle(hit):
            room.handleTaps += 1
            if let handle = FixedGridEditInteraction.Handle(hit) { edit.send(.handleTap(handle)) }      // its time bubble (the editing parts show it)
        case let .chooseOther(hit):
            // Another editable event: the session moves to it (or, with changes, leaves). Anything else is outside the event.
            if case let .event(id) = hit, let found = touched(at: point), let target = editTarget(id, in: found) { edit.send(.tapEvent(target)) }
            else { edit.send(.tapOutside) }
        case .endEditing: edit.send(.tapOutside)
        case .chosenBody: if let target = edit.session?.target { edit.send(.tapEvent(target)) }     // lets a chosen handle go
        }
    }

    private func handleLongPress(_ phase: GridGestureHooks.Phase, at point: CGPoint, start: FixedGridGestures.Start) {
        guard phase == .began else { return carry(phase, at: point) }
        switch FixedGridGestures.longPress(start: start, mode: gestureMode) {
        case .none: break
        case let .edit(id):
            pickUpEvent(id, at: point)
        case .liftChosen:
            liftChosen(at: point)
        case .notice:
            break
        case .createDraft:
            room.createPresses += 1
            pickUpNewEvent(at: point)
        case let .pickUpTransaction(id):
            pickUpTransaction(id, at: point)
        }
    }

    /// A long press on an event in browse: a session opens on it (its handles, its time wheel, its title) and the event is in the hand at once. One that cannot
    /// be edited here opens its details instead.
    private func pickUpEvent(_ id: BlockID, at point: CGPoint) {
        guard move.phase == .resting, edit.session == nil, let found = touched(at: point), let block = found.timeline.blocks.first(where: { $0.id == id }) else { return }
        guard block.isEditable, FixedGridEditor.refusal(for: block, zone: zone) == nil else { onSelect(.event(block)); return }
        edit.send(.enter(FixedGridEditInteraction.Target(day: found.timeline.day, block: block)))
        guard edit.session != nil else { return }
        lift(day: found.timeline.day, startMinute: block.startMinute, endMinute: block.endMinute, totalMinutes: found.timeline.totalMinutes, at: point)
    }

    /// A long press on the chosen event while editing: it comes off its place and follows the finger.
    private func liftChosen(at point: CGPoint) {
        guard move.phase == .resting, let target = edit.state.editing?.target, edit.session?.committing != true,
              let segment = editor?.draft?.segment(on: target.day), let timeline = model.cachedTimeline(for: target.day) else { return }
        lift(day: target.day, startMinute: segment.startMinute, endMinute: segment.endMinute, totalMinutes: timeline.totalMinutes, at: point)
    }

    /// The edited event in the hand: `placing` follows the finger like a new event's card; put down, the draft moves to where it would land.
    private func lift(day: LocalDate, startMinute: Int, endMinute: Int, totalMinutes: Int, at point: CGPoint) {
        let axis = planner.axis(for: day, partition: frame(zoom: pinch.zoom, viewport: pinch.viewportHeight, width: room.width).shown, zone: zone)
        let placement = FixedGridCreatePlacement(day: day, fingerMinute: startMinute, dayMinutes: totalMinutes, durationMinutes: endMinute - startMinute) { axis.y(minute: $0) - point.y }
        placing = placement
        carriedFinger = point
        carriedGrabX = newCardFrame(day: day, startMinute: placement.startMinute, endMinute: placement.endMinute, axis: axis).minX - point.x
        lifted = true
        Haptics.pickUp()
    }

    /// A long press on a transaction's line: the transaction comes off the grid and follows the finger; the event card under it is outlined.
    private func pickUpTransaction(_ id: String, at point: CGPoint) {
        guard move.phase == .resting, edit.session == nil, let found = touched(at: point),
              let display = found.plan.lines.first(where: { $0.id == id })?.display else { return }
        let transactionID = LedgerEntryID(rawValue: id)
        let linked = found.timeline.blocks.first { $0.allocations.contains { $0.transactionID == transactionID } }?.eventKey
        room.carryPickUps += 1
        carrying = FixedGridTransactionCarry(
            transactionID: transactionID, title: display.title, amount: display.amount, flow: display.flow, linkedEvent: linked, at: point, cards: eventCards()
        )
        Haptics.pickUp()
    }

    /// The finger carrying a transaction moved or lifted. Lifted on an event's card: the transaction belongs to that event. Anywhere else, or cancelled (a
    /// second finger made it a pinch): nothing changes.
    private func carryTransaction(_ phase: GridGestureHooks.Phase, at point: CGPoint) {
        guard var carry = carrying else { return }
        switch phase {
        case .began: break
        case .moved:
            if carry.move(to: point, cards: eventCards()) { Haptics.snap() }
            carrying = carry
        case .ended:
            carry.move(to: point, cards: eventCards())
            carrying = nil
            if case let .link(transaction, event) = carry.outcome {
                room.carryLinks += 1
                Haptics.enterEdit()
                Task { _ = await model.perform(ActivityEditing.link(transaction, event: event, now: Int64(Date().timeIntervalSince1970 * 1_000))) }
            }
        case .cancelled:
            carrying = nil
        }
    }

    /// The event cards on screen, in grid coordinates, back to front (for where a carried transaction would go).
    private func eventCards() -> [FixedGridTransactionCarry.Card] {
        let width = room.width, viewport = pinch.viewportHeight
        guard viewport > 1, width > Self.gutter else { return [] }
        let geometry = geometry(width: width)
        let frame = frame(zoom: pinch.zoom, viewport: viewport, width: width)
        let first = Int(position.rounded(.down))
        return (first...(first + Self.visibleColumns)).flatMap { epoch -> [FixedGridTransactionCarry.Card] in
            guard let timeline = model.cachedTimeline(for: LocalDate(daysSinceUnixEpoch: epoch)), let column = frame.column(epoch) else { return [] }
            let columnX = geometry.x(ofDay: Double(epoch), at: position)
            let plan = plan(timeline, column: column, source: column.dominant, frame: frame, layoutWidth: Self.gutter + geometry.dayWidth)
            return plan.events.map { item in
                FixedGridTransactionCarry.Card(eventKey: item.block.eventKey, title: item.block.title, frame: item.drawnFrame.offsetBy(dx: columnX, dy: 0))
            }
        }
    }

    /// The day column under a grid point's x, one of the days on screen (the nearest one past either side).
    private func epoch(atX x: CGFloat) -> Int? {
        let width = room.width
        guard width > Self.gutter else { return nil }
        let first = Int(position.rounded(.down))
        let raw = Int((position + Double((max(x, Self.gutter) - Self.gutter) / geometry(width: width).dayWidth)).rounded(.down))
        return min(max(raw, first), first + Self.visibleColumns - 1)
    }

    /// A long press on empty grid: a new event, an hour long, is under the finger (its start on the 15-minute line at or before it) and follows it.
    private func pickUpNewEvent(at point: CGPoint) {
        guard move.phase == .resting, edit.session == nil, let found = touched(at: point) else { return }
        let day = found.timeline.day
        guard let fingerMinute = minute(atY: point.y, day: day) else { return }
        let viewport = pinch.viewportHeight
        let axis = planner.axis(for: day, partition: frame(zoom: pinch.zoom, viewport: viewport, width: room.width).shown, zone: zone)
        let placement = FixedGridCreatePlacement(day: day, fingerMinute: fingerMinute, dayMinutes: found.timeline.totalMinutes) { axis.y(minute: $0) - point.y }
        placing = placement
        carriedFinger = point
        carriedGrabX = newCardFrame(day: day, startMinute: placement.startMinute, endMinute: placement.endMinute, axis: axis).minX - point.x
        Haptics.pickUp()
    }

    /// The finger carrying a new event moved or lifted. Lifted: an edit session opens on the event where it is, with its name being typed (the calendars to
    /// choose from above it; its handles change its length). Cancelled (a second finger made it a pinch): nothing.
    private func carry(_ phase: GridGestureHooks.Phase, at point: CGPoint) {
        if carrying != nil { return carryTransaction(phase, at: point) }
        guard var placement = placing else { return }
        switch phase {
        case .began: break
        case .moved, .ended:
            carriedFinger = point
            if let epoch = epoch(atX: point.x), let timeline = model.cachedTimeline(for: LocalDate(daysSinceUnixEpoch: epoch)),
               let minute = minute(atY: point.y + placement.grabOffset, day: timeline.day),
               placement.move(to: timeline.day, minute: minute, dayMinutes: timeline.totalMinutes) {
                Haptics.snap()
            }
            guard phase == .ended else { placing = placement; return }
            placing = nil
            carriedFinger = nil
            if lifted {
                lifted = false
                if let target = edit.session?.target { edit.send(.moved(target.moved(to: placement.day, startMinute: placement.startMinute, endMinute: placement.endMinute))) }
                return
            }
            edit.send(.enter(placement.target))
            if edit.session?.target.isNew == true { edit.send(.tapTitle) }
        case .cancelled:
            placing = nil
            carriedFinger = nil
            lifted = false
        }
    }

    private func handleHandleDrag(_ phase: GridGestureHooks.Phase, at point: CGPoint, hit: EditHit) {
        switch phase {
        case .began: room.handleDrags += 1; room.dragPositions.append(position)
        case .moved: room.handleSteps += 1
        case .ended, .cancelled: room.dragPositions.append(position)
        }
        // The draft follows the finger (the editing parts), the edge kept at the distance from the finger it had when the drag began.
        if let handle = FixedGridEditInteraction.Handle(hit), let target = edit.state.editing?.target {
            if phase == .began, let card = gestureMode.target?.frame {
                room.grabOffset = edgeY(handle, of: target, card: card) - point.y
            }
            edit.send(.handleDrag(phase, handle, point: point, minute: minute(atY: point.y + room.grabOffset, day: target.day)))
        }
        axisTick &+= 1
    }

    // MARK: Edit sessions

    /// The session's grid commands come here; the rest go to the parts that edit (`FixedGridEditor`), which save through `AppModel.save`.
    private func connectEditing() {
        edit.grid = { performGrid($0) }
        let editor = editor ?? FixedGridEditor(router: edit, environment: FixedGridEditor.Environment(
            zone: zone,
            generation: { model.dataGeneration },
            block: { target in
                model.cachedTimeline(for: target.blockDay).flatMap { timeline in
                    timeline.blocks.first { $0.id == target.blockID } ?? timeline.blocks.first { $0.eventKey == target.eventKey }
                }
            },
            save: { await model.save($0) },
            stepped: { Haptics.snap() },
            calendars: { model.calendars },
            create: { await model.perform(.createEvent(CreateEventInput(draft: $0))) },
            meet: { key, people, headcount in
                for person in people { _ = await model.perform(ActivityEditing.setParticipant(person, on: true, event: key, now: model.nowMilliseconds)) }
                if let headcount {
                    _ = await model.perform(.setHeadcount(SetHeadcountInput(target: .event(key), headcount: headcount, provenance: ActivityEditing.provenance(now: model.nowMilliseconds))))
                }
            }
        ))
        self.editor = editor
        edit.editor = { editor.perform($0) }
    }

    /// Follows the chosen handle with the precision bubble: its centre is taken once at 1× (the partition is frozen during a session), and the tracker
    /// scales it by the zoom and moves it by the scroll every display frame.
    private func followBubble() {
        guard let edge = editor?.edge, let card = gestureMode.target?.frame, pinch.zoom > 0 else {
            room.bubbleAnchor = nil
            bubbleTracker.stop()
            return
        }
        let centre = edge == .start ? EditHit.startHandle(of: card) : EditHit.endHandle(of: card)
        room.bubbleAnchor = CGPoint(x: centre.x, y: centre.y / pinch.zoom)
        bubbleTracker.track { [room, pinch] in
            guard let unit = room.bubbleAnchor else { return nil }
            return PrecisionAnchorTracker.viewportPoint(
                content: PrecisionAnchorTracker.contentPoint(atUnitZoom: unit, zoom: pinch.zoom), offset: pinch.currentOffset?() ?? 0
            )
        }
    }

    /// The grid's commands of the session.
    private func performGrid(_ command: FixedGridEditInteraction.Command) {
        switch command {
        case let .freeze(session, target): freezeGrid(session, target: target)
        case let .retarget(session, target):
            guard let frozen = room.frozen, frozen.session == session else { return }
            planner.retarget(frozen.freeze, target: model.cachedTimeline(for: target.blockDay)?.blocks.first { $0.id == target.blockID }.map { (target.blockDay, $0) })
            axisTick &+= 1
        case let .unfreeze(session, request): unfreezeGrid(session, anchor: request)
        default: break
        }
    }

    /// Opens a session on an event: the time partition and the engine's decisions on screen are frozen (`FixedGridBrowseModel.freeze`) and the original is
    /// taken (`FixedGridEditBaseline`). The days keep being read meanwhile.
    private func freezeGrid(_ session: Int, target: FixedGridEditInteraction.Target) {
        let viewport = pinch.viewportHeight
        let inputs = inputs(viewport: viewport, width: room.width)
        let columns = FixedGridColumns.columns(days: geometry(width: room.width).renderedDays(at: position), position: position, bounds: move.bounds)
        let windows = FixedGridColumns.windows(of: columns)
        var days: [LocalDate: DayTimeline] = [:]
        for window in windows { for offset in -1...2 { let day = LocalDate(daysSinceUnixEpoch: window + offset); days[day] = model.cachedTimeline(for: day) } }
        let block = model.cachedTimeline(for: target.day)?.blocks.first { $0.id == target.blockID }
        let baseline = FixedGridEditBaseline(dataGeneration: model.dataGeneration, dataRevision: model.dataRevision, days: days, target: block.map { (target.day, $0) })
        let freeze = planner.freeze(
            position: position, bounds: move.bounds, windows: windows, zoomKey: planner.plannedZoomKey(current: pinch.zoom, settling: pinch.settlingZoom),
            inputs: inputs, baseline: baseline
        )
        room.frozen = (session, freeze)
        room.unfreezeAnchor = nil
        Haptics.enterEdit()
        axisTick &+= 1
    }

    /// Ends the grid's part of a session: the axis eases from what was frozen to what is planned now, and the decisions crossfade with it (`unfreeze`,
    /// `thawing`). After a save the edited edge stays at its height through the easing; otherwise the time at the middle does.
    private func unfreezeGrid(_ session: Int, anchor request: FixedGridEditInteraction.AnchorRequest) {
        guard let frozen = room.frozen, frozen.session == session else { return }
        let viewport = pinch.viewportHeight
        if viewport > 1, room.width > Self.gutter, move.phase == .resting {
            let shown = planner.shared(position: position, bounds: move.bounds, inputs: inputs(viewport: viewport, width: room.width))   // the frozen one
            let anchor = FixedGridUnfreezeAnchor.resolve(
                request, frozen: shown, projection: { planner.projection(for: $0, zone: zone) }, zoom: pinch.zoom, viewport: viewport, offset: pinch.currentOffset?() ?? 0
            )
            room.unfreezeAnchor = anchor.isEdge ? anchor : nil
        }
        room.anchorDrift = nil
        planner.unfreeze(frozen.freeze)
        room.frozen = nil
        axisTick &+= 1
    }

    /// While editing: the chosen card where the draft has it (outlined; filled in once its time differs) and its handles. The touches are the grid's
    /// recognizers' (`FixedGridGestures`), so none of this takes any.
    @ViewBuilder
    private func editHandles() -> some View {
        if let target = gestureMode.target, !target.frame.isNull {
            let chosen = editor?.edge
            ZStack(alignment: .topLeading) {
                if let editor, let draft = editor.draft, let colorHex = draftColor(editor) {
                    DraftCard(colorHex: colorHex, title: editor.shownTitle, draft: draft, zone: zone, frame: target.frame, isChanged: editor.isChanged)
                }
                if edit.session?.committing != true {                                   // no handles while the save is answered
                    if target.canResizeStart { handleDot(EditHit.startHandle(of: target.frame), chosen: chosen == .start) }
                    if target.canResizeEnd { handleDot(EditHit.endHandle(of: target.frame), chosen: chosen == .end) }
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// The colour the edited card is filled with: its calendar's (a new event's chosen calendar). `nil`: the event is not found (nothing is drawn).
    private func draftColor(_ editor: FixedGridEditor) -> String?? {
        guard let target = editor.target else { return nil }
        if editor.isNew { return .some(model.calendars.first { $0.id == editor.calendarID }?.colorHex) }
        return model.cachedTimeline(for: target.blockDay)?.blocks.first { $0.eventKey == target.eventKey }.map { $0.calendarColorHex }
    }

    /// A new event's card in the grid's coordinates: across its day's column, from its start on the axis drawn now, as tall as its time there but never too
    /// thin to name it (in a folded stretch of the day an hour may be only a few points; the grid gives it its room once it is saved).
    private func newCardFrame(day: LocalDate, startMinute: Int, endMinute: Int, axis: ElapsedMinuteAxisMapping) -> CGRect {
        let geometry = geometry(width: room.width)
        let top = axis.y(minute: startMinute)
        return CGRect(
            x: geometry.x(ofDay: Double(day.daysSinceUnixEpoch), at: position) + axis.gutterWidth + 2, y: top,
            width: max(0, geometry.dayWidth - Self.trailing - 4), height: max(Self.newCardMinimumHeight, axis.y(endMinute: endMinute) - top)
        )
    }

    /// The least a new event's card is drawn (its title and time written in it).
    private static let newCardMinimumHeight: CGFloat = 36

    /// Where an edge of the edited event really is on the axis drawn now (a new event's card may be drawn taller than its time; its handle drags from the
    /// real edge, so the first step does not jump).
    private func edgeY(_ handle: FixedGridEditInteraction.Handle, of target: FixedGridEditInteraction.Target, card: CGRect) -> CGFloat {
        guard target.isDrawnFromDraft, let segment = editor?.draft?.segment(on: target.day) else { return handle == .start ? card.minY : card.maxY }
        let axis = planner.axis(for: target.day, partition: frame(zoom: pinch.zoom, viewport: pinch.viewportHeight, width: room.width).shown, zone: zone)
        return handle == .start ? axis.y(minute: segment.startMinute) : axis.y(endMinute: segment.endMinute)
    }

    /// The new event a long press carries: the card in the hand, following the finger freely; where it would be put down only outlined (on the 15-minute
    /// lines), with that start written on the hour axis.
    @ViewBuilder
    private func placementPreview(partition: TemporalGridPartition) -> some View {
        if let placing {
            let axis = planner.axis(for: placing.day, partition: partition, zone: zone)
            let card = newCardFrame(day: placing.day, startMinute: placing.startMinute, endMinute: placing.endMinute, axis: axis)
            let start = zone.dayBounds(placing.day).start + Int64(placing.startMinute) * 60_000
            let end = start + Int64(placing.durationMinutes) * 60_000
            let calendar = model.calendars.first(where: \.isWritable)
            let colorHex = lifted ? (editor.flatMap(draftColor) ?? nil) : calendar?.colorHex
            let finger = carriedFinger ?? CGPoint(x: card.minX - carriedGrabX, y: card.minY - placing.grabOffset)
            let carried = CGRect(x: finger.x + carriedGrabX, y: finger.y + placing.grabOffset, width: card.width, height: card.height)
            ZStack(alignment: .topLeading) {
                DropOutline(colorHex: colorHex, frame: card)
                GutterTimeMark(text: DraftCard.clock(EventSaveTime.date(start), zone: zone), y: card.minY, gutter: Self.gutter, lineTo: card.minX)
                CarriedCard(colorHex: colorHex, title: lifted ? (editor?.shownTitle ?? "") : FixedGridEditor.newTitle, frame: carried, time: DraftCard.clock(EventSaveTime.date(start), zone: zone) + " – " + DraftCard.clock(EventSaveTime.date(end), zone: zone))
            }
            .allowsHitTesting(false)
        }
    }

    /// A carried transaction: its card under the finger, and the event it would go into outlined.
    @ViewBuilder
    private func carryPreview() -> some View {
        if let carrying {
            ZStack(alignment: .topLeading) {
                if let target = carrying.target {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: carrying.willLink ? 3 : 1)
                        .frame(width: target.frame.width, height: target.frame.height)
                        .offset(x: target.frame.minX, y: target.frame.minY)
                }
                CarriedTransactionCard(title: carrying.title, amount: carrying.amount, flow: carrying.flow, into: carrying.willLink ? carrying.target?.title : nil)
                    .fixedSize()
                    .offset(x: carrying.finger.x - 40, y: carrying.finger.y - 64)    // above the finger, so it is seen
            }
            .allowsHitTesting(false)
        }
    }

    /// While a handle of the edited card is dragged, the time of that edge is written on the hour axis too.
    @ViewBuilder
    private func draggedEdgeMark() -> some View {
        if let editor, editor.isDragging, let edge = editor.edge, let draft = editor.draft, let target = edit.state.editing?.target,
           let card = gestureMode.target?.frame, !card.isNull {
            let y = edgeY(edge == .start ? .start : .end, of: target, card: card)
            GutterTimeMark(text: DraftCard.clock(edge == .start ? draft.startDate : draft.endDate, zone: zone), y: y, gutter: Self.gutter, lineTo: card.minX)
                .allowsHitTesting(false)
        }
    }

    private func handleDot(_ center: CGPoint, chosen: Bool) -> some View {
        let size: CGFloat = chosen ? 16 : 12
        return Circle().fill(chosen ? Color.accentColor : Color.white).overlay(Circle().stroke(Color.accentColor, lineWidth: 2)).frame(width: size, height: size)
            .offset(x: center.x - size / 2, y: center.y - size / 2)
    }

    /// DEBUG probe: what the session sees.
    private var editProbeText: String {
        let changes = planner.frozen.map { $0.baseline.changes(dataGeneration: model.dataGeneration, dataRevision: model.dataRevision) { model.cachedTimeline(for: $0) } }
        let outside: String
        if let changes {
            outside = changes.isClean ? "외부 변경 없음"
                : "외부 변경: \(changes.reloaded ? "재로드 " : "")\(changes.changedDays.isEmpty ? "" : "날짜 \(changes.changedDays.count) ")대상 \(changes.target)"
        } else {
            outside = "세션 없음"
        }
        let moved = zip(room.dragPositions.dropLast(), room.dragPositions.dropFirst()).enumerated().filter { $0.offset % 2 == 0 }.contains { $0.element.0 != $0.element.1 }
        let state: String
        if let session = edit.session {
            let handle: String
            switch session.handle {
            case .none: handle = "핸들 없음"
            case let .selected(h): handle = h == .start ? "시작 선택" : "끝 선택"
            case let .dragging(h): handle = h == .start ? "시작 끄는 중" : "끝 끄는 중"
            }
            state = "#\(session.id) \(handle)\(session.isDirty ? " · 변경" : "")\(session.committing ? " · 저장 중" : "")\(session.asking != nil ? " · 확인 대기" : "")"
        } else {
            state = "꺼짐"
        }
        let drift = room.anchorDrift.map { String(format: " · 앵커 오차 %.2fpt", Double($0)) } ?? ""
        return "편집 시험 \(state) · 핸들 탭 \(room.handleTaps) · 핸들 끌기 \(room.handleDrags)(\(room.handleSteps)) · 날짜 이동 \(moved ? "있음" : "없음") · 만들기 \(room.createPresses) · 거래 들기 \(room.carryPickUps)/연결 \(room.carryLinks) · \(outside)\(drift) · 마지막 \(edit.log.last.map(Self.probeName) ?? "—")"
    }

    private static func probeName(_ command: FixedGridEditInteraction.Command) -> String {
        switch command {
        case .freeze: "freeze"
        case .retarget: "retarget"
        case let .unfreeze(_, anchor): anchor == .middle ? "unfreeze(가운데)" : "unfreeze(가장자리)"
        case .began: "began"
        case .handle: "handle"
        case .dragHandle: "drag"
        case let .rename(_, on): on ? "rename" : "rename(끝)"
        case .commit: "commit"
        case .discard: "discard"
        case .moved: "moved"
        case .askExit: "ask"
        case let .ended(_, reason): "ended(\(reason))"
        }
    }

    /// One tap handler for everything of the days, decided by the plan that was drawn. Taps count when the days are at rest (a finger that comes down on a moving day line stops
    /// it instead).
    private func select(at point: CGPoint) {
        guard move.phase == .resting, let found = touched(at: point) else { return }
        let timeline = found.timeline, plan = found.plan
        switch found.hit {
        case .nothing: break
        case let .event(id): perform(.event(id), in: timeline, plan: plan)
        case let .line(id): perform(.line(id), in: timeline, plan: plan)
        case let .overflow(id): perform(.overflow(id), in: timeline, plan: plan)
        case let .choose(candidates):
            choice = TouchChoice(options: candidates.map { candidate in
                TouchChoice.Option(id: "\(candidate)", label: FixedGridTouch.label(of: candidate, in: timeline, plan: plan)) { chose(candidate, in: timeline, plan: plan) }
            })
        }
    }

    /// A choice from "무엇을 선택할까요?". The button runs while the dialog is still going away, and a details sheet asked for in that moment is dropped (a
    /// transaction chosen there opened nothing), so the sheet is asked for once the dialog is gone.
    private func chose(_ candidate: DayRenderPlan.Candidate, in timeline: DayTimeline, plan: DayRenderPlan) {
        guard let selection = FixedGridTouch.selection(for: candidate, in: timeline, plan: plan) else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            onSelect(selection)
        }
    }

    /// A tap opens the details of what it touched (an event is edited by a long press, as a transaction is).
    private func perform(_ candidate: DayRenderPlan.Candidate, in timeline: DayTimeline, plan: DayRenderPlan) {
        if let selection = FixedGridTouch.selection(for: candidate, in: timeline, plan: plan) { onSelect(selection) }
    }

    // MARK: Moving the days

    /// The swipe is `DayMoveModel`'s `drag`/`release` (days per second); this reads its position back. A finger coming down stops a flight under it at once; a new drag takes over
    /// from the position the flight had reached; nothing is ignored while days are moving.
    private func handleDateDrag(_ phase: DateDragPhase, width: CGFloat) {
        let geometry = geometry(width: width)
        switch phase {
        case .touchDown:
            guard move.phase == .settling else { return }
            caughtTarget = move.target
            flight = nil
            move.beginDrag()
            takeOverSelection()
            applyMove()
        case .began:
            BrowseProbe.mark(.dragBegan)
            caughtTarget = nil
            flight = nil
            if move.phase != .dragging { move.beginDrag() }
            takeOverSelection()
            dragStart = move.position
        case .changed(let translation):
            if dragStart == nil { dragStart = move.position; if move.phase != .dragging { move.beginDrag() } }
            let raw = geometry.position(startingAt: dragStart ?? move.position, translation: translation)
            move.drag(to: DayPrefetchPolicy.browse.clampedPosition(raw, selected: selectedEpoch))
            applyMove()
        case .ended(let velocity):
            BrowseProbe.mark(.released)
            dragStart = nil
            move.release(velocity: -Double(velocity / geometry.dayWidth))
            holdToHop()
            startTicker()
        case .cancelled:
            dragStart = nil
            move.release(velocity: 0)
            holdToHop()
            startTicker()
        case .touchUp:
            guard let caught = caughtTarget, move.phase == .dragging, dragStart == nil else { return }
            caughtTarget = nil
            move.retarget(to: caught)                       // nothing swiped: the flight goes on to where it was going
            startTicker()
        }
    }

    /// A release carries the days at most `maximumHop` from the selected day (a swipe never skips a day, as in Browse): the model's own limit is from where the finger was, which
    /// may already be a day away.
    private func holdToHop() {
        let target = FixedGridMove.held(target: move.target, selected: selectedEpoch)
        if target != move.target { move.retarget(to: target) }
    }

    /// A new touch on a move that has already passed a day: the selected day is that day now, so the next flick is measured from it (and its days are kept).
    private func takeOverSelection() {
        let delta = FixedGridMove.takeOver(position: move.position, selected: selectedEpoch)
        guard delta != 0 else { return }
        moveSelectedDay(by: delta)
        rebase(keeping: move.position)
    }

    private func moveSelectedDay(by delta: Int) {
        ownEpoch = selectedEpoch + delta
        onMoveDays(delta)
    }

    /// The model around the selected day, with the days either side the cache keeps; at `position` (dragging) or at rest on the day.
    private func rebase(keeping position: Double?) {
        let selected = selectedEpoch
        var next = DayMoveModel(day: selected, bounds: FixedGridMove.bounds(around: selected), maximumHop: DayPrefetchPolicy.browse.maximumHop)
        if let position { next.beginDrag(); next.drag(to: position) }
        move = next
    }

    /// Show the model's position: the day and fraction the columns and the time blend are drawn at, the week strip's pending day, the days read ahead, and the scroll that keeps
    /// the anchor.
    private func applyMove() {
        let started = CFAbsoluteTimeGetCurrent()
        let probe = BrowseProbe.begin(.applyMove)
        defer { costs.record(apply: (CFAbsoluteTimeGetCurrent() - started) * 1000); BrowseProbe.end(probe) }
        position = move.position
        // A move to a day something else picked: the week strip is on that day already.
        let pending = flight != nil ? 0 : FixedGridMove.pending(position: move.position, selected: selectedEpoch)
        if room.pending != pending || pendingDays != pending && !ProbeExperiment.stripOff {
            BrowseProbe.mark(.boundary)
            room.pending = pending
            if !ProbeExperiment.stripOff { pendingDays = pending }
            BrowseProbe.measure(.haptics) {
                if let haptic = room.haptic { haptic.selectionChanged(); haptic.prepare() } else { Haptics.snap() }
            }
        }
        prefetch()
        holdAnchor()
    }

    /// The scroll that keeps the time at the middle of the screen where it was, on the partition drawn now (the days moving, or the axis easing to a new plan).
    private func holdAnchor() {
        let userMoved = pinch.consumeUserMoved()
        let viewport = pinch.viewportHeight
        if restoringScroll, room.unfreezeAnchor == nil { anchorState.release(at: move.position); return }
        guard viewport > 1, room.width > Self.gutter else { anchorState.release(at: move.position); room.unfreezeAnchor = nil; return }
        let inputs = inputs(viewport: viewport, width: room.width)
        let bounds = move.bounds
        if let anchor = room.unfreezeAnchor {
            // A session's end after a save: the edited edge stays at its height through the easing; the person scrolling or the days moving let it go.
            if !userMoved, move.phase == .resting {
                let shown = planner.shared(position: move.position, bounds: bounds, inputs: inputs, flight: flight)
                if pinch.setOffset?(anchor.offset(on: shown, zoom: pinch.zoom, viewport: viewport).offset) == true {
                    guard !planner.isEasing else { return }
                    room.anchorDrift = anchor.drift(on: shown, zoom: pinch.zoom, viewport: viewport, offset: pinch.currentOffset?() ?? 0)
                }
            }
            room.unfreezeAnchor = nil
            anchorState.release(at: move.position)
            return
        }
        let result = anchorState.offset(
            forPosition: move.position, currentOffset: pinch.currentOffset?() ?? 0, userMoved: userMoved, zoom: pinch.zoom, viewport: viewport, focal: viewport / 2,
            partitionAt: { planner.shared(position: $0, bounds: bounds, inputs: inputs, flight: flight) }
        )
        // Not applied while the person has the scroll in hand: the anchor is taken again from where they leave it.
        if pinch.setOffset?(result.offset) == false { anchorState.release(at: move.position) }
    }

    /// Draws the frames of an axis easing to a new plan (a day arrived while it was held), keeping the time at the middle of the screen where it is.
    private func easeAxis() {
        guard !room.easing else { return }
        room.easing = true
        Task { @MainActor in
            defer { room.easing = false }
            repeat {
                try? await Task.sleep(for: .milliseconds(8))
                BrowseProbe.measure(.transitionTick) {
                    axisTick &+= 1
                    if move.phase == .resting { holdAnchor() }
                }
            } while planner.isEasing
        }
    }

    /// The days the position needs are read ahead (`AppModel.prefetch`) whenever what it needs changes, never on every frame.
    private func prefetch() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-browse-temporal-noprefetch") { return }
        #endif
        let target = move.phase == .resting ? nil : move.target
        let needed = DayPrefetchPolicy.neededDays(position: move.position, target: target)
        guard needed != lastNeeded else { return }
        lastNeeded = needed
        let position = move.position
        Task { await model.prefetch(forPosition: position, target: target) }
    }

    /// Advances the spring by real elapsed time, once per display frame, while there is something to settle.
    private func startTicker() {
        guard !ticking else { return }
        ticking = true
        Task { @MainActor in
            let clock = ContinuousClock()
            var last = clock.now
            while move.phase == .settling {
                try? await Task.sleep(for: .milliseconds(8))
                let now = clock.now
                let elapsed = now - last
                last = now
                move.advance(by: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
                applyMove()
            }
            ticking = false
            pinch.stopPace?()
            if move.phase == .resting { commit() }
        }
    }

    /// The days have come to rest: the selected day, the week strip and the cache take the day the line is on.
    private func commit() {
        BrowseProbe.mark(.rested)
        writeProbeSoon()
        let day = Int(move.position.rounded())
        if day != selectedEpoch { moveSelectedDay(by: day - selectedEpoch) }
        flight = nil
        rebase(keeping: nil)
        position = move.position
        if pendingDays != 0 { pendingDays = 0 }
        room.pending = 0
        lastNeeded = nil
        prefetch()
        selectionChangedOutside()
    }

    /// The selected day was changed by something else (the week strip, the header's arrows, "오늘"): the days run to it from wherever they are now (resting, in a
    /// flight, or under a finger), or jump when it is far. A change this screen made itself (`ownEpoch`) is not one.
    private func selectionChangedOutside() {
        if let own = ownEpoch {
            ownEpoch = nil
            if own == selectedEpoch { return }
        }
        guard move.phase != .resting || Double(selectedEpoch) != move.position else { return }
        if edit.state.editing != nil, !lifted { edit.send(.selectedDayChanged(model.selectedDay)) }   // a session is on the days it began on: the grid lets go first
        caughtTarget = nil
        dragStart = nil
        let here = move.position
        let distance = Double(selectedEpoch) - here
        guard abs(distance) <= 3 else {
            flight = nil
            if pendingDays != 0 { pendingDays = 0 }
            room.pending = 0
            rebase(keeping: nil); position = move.position; anchorState.release(at: move.position)
            return
        }
        let from = distance > 0 ? Int(here.rounded(.down)) : Int(here.rounded(.up))
        let low = min(from, selectedEpoch) - 1, high = max(from, selectedEpoch) + 2
        var next = DayMoveModel(day: from, bounds: low...high, maximumHop: max(1, abs(selectedEpoch - from)))
        if here != Double(from) { next.beginDrag(); next.drag(to: here) }
        next.retarget(to: selectedEpoch)
        flight = (from, selectedEpoch)
        if pendingDays != 0 { pendingDays = 0 }
        room.pending = 0
        move = next
        if next.phase == .resting { commit() } else { startTicker() }
    }

    // MARK: DEBUG scripts

    private static func argument(_ name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    /// `-browse-temporal-zoom <1...8>` starts at that zoom; `-browse-temporal-script zoom|days` plays a short sequence (what a pinch and a run of flicks do, without fingers);
    /// `-browse-temporal-log <path>` writes what it measured. DEBUG builds only.
    private func runDebugScript() async {
        #if DEBUG
        let zoom = Self.argument("-browse-temporal-zoom").flatMap(Double.init).map { CGFloat($0) }
        let script = Self.argument("-browse-temporal-script")
        guard zoom != nil || script != nil else { return }
        while pinch.viewportHeight < 2 || room.width < 2 { try? await Task.sleep(for: .milliseconds(50)) }
        try? await Task.sleep(for: .milliseconds(600))
        if let zoom { pinch.setZoom?(zoom, pinch.viewportHeight / 2); restedZoomKey = FixedGridBrowseModel.zoomKey(zoom) }
        guard let script else { return }
        try? await Task.sleep(for: .milliseconds(800))
        costs = Costs()
        BrowseProbeRecorder.shared.start()
        let meter = FrameMeter()
        meter.start()
        let started = CFAbsoluteTimeGetCurrent()
        let reads = model.dayReads
        var passReports: [String] = []
        switch script {
        case "zoom":
            // One pinch 1 → 8 → 1 through the recognizer's own steps (`drivePinch`): what a person's pinch does, not a slider.
            let steps = 160, focal = pinch.viewportHeight / 2
            pinch.drivePinch?(.began, 1, focal)
            for step in 0...steps {
                let t = Double(step) / Double(steps)
                let z = 1 + 7 * CGFloat(t < 0.5 ? t * 2 : 2 - t * 2)
                let begun = CFAbsoluteTimeGetCurrent()
                pinch.drivePinch?(.changed, z, focal)
                costs.record(apply: (CFAbsoluteTimeGetCurrent() - begun) * 1000)
                try? await Task.sleep(for: .milliseconds(16))
            }
            pinch.drivePinch?(.ended, 1, focal)
            try? await Task.sleep(for: .milliseconds(600))
        case "hold":
            // `-browse-temporal-hold <fraction>`: the days dragged to that fraction of the next day and held there (for screenshots of a move in progress).
            let fraction = Self.argument("-browse-temporal-hold").flatMap(Double.init) ?? 0.5
            move.beginDrag()
            move.drag(to: Double(selectedEpoch) + fraction)
            applyMove()
            try? await Task.sleep(for: .seconds(30))
        case "rubber":
            // Past 8× and let go (it eases back to 8×), then past 1× from 8× and let go (back to 1×), twice. Each pinch 0.5 s, 8 ms steps.
            let focal = pinch.viewportHeight * 0.4
            func pinchTo(_ scale: CGFloat) async {
                pinch.drivePinch?(.began, 1, focal)
                for step in 1...60 { pinch.drivePinch?(.changed, 1 + (scale - 1) * CGFloat(step) / 60, focal); try? await Task.sleep(for: .milliseconds(8)) }
                pinch.drivePinch?(.ended, scale, focal)
                try? await Task.sleep(for: .milliseconds(900))
            }
            for _ in 0..<2 {
                await pinchTo(10)                      // 1× → stretched past 8×
                await pinchTo(0.08)                    // 8× → stretched below 1×
            }
        case "days", "days-twice":
            // Rapid taps add up, a reversal in flight, then a longer run. "days-twice" plays it once to build everything, then measures the second time.
            for pass in 0..<(script == "days-twice" ? 2 : 1) {
                if pass == 1 { while move.phase != .resting { try? await Task.sleep(for: .milliseconds(50)) }; try? await Task.sleep(for: .milliseconds(600)); costs = Costs() }
                for (delta, wait) in [(1, 120), (1, 150), (-1, 200), (-1, 100), (1, 500), (1, 140), (1, 140), (-1, 900), (1, 60), (-2, 1200)] {
                    move.retarget(by: delta)
                    startTicker()
                    try? await Task.sleep(for: .milliseconds(wait))
                }
            }
            while move.phase != .resting { try? await Task.sleep(for: .milliseconds(50)) }
            try? await Task.sleep(for: .milliseconds(400))
        case "swipes", "swipes-zoomed":
            // Real drag phases through the same handler the recognizer calls: slow drags across the halfway line and back, past it, a hard flick, a touch
            // that catches a flight and swipes on, a reversal mid-flight. 8 ms per finger sample (120 Hz touches).
            if script == "swipes-zoomed" { pinch.setZoom?(3, pinch.viewportHeight / 2); restedZoomKey = FixedGridBrowseModel.zoomKey(3); try? await Task.sleep(for: .milliseconds(600)) }
            let width = room.width
            let day = geometry(width: width).dayWidth
            func swipe(_ points: [CGFloat], velocity: CGFloat, caught: Bool = false) async {
                if caught { handleDateDrag(.touchDown, width: width) }
                handleDateDrag(.began, width: width)
                for x in points { handleDateDrag(.changed(translationX: x), width: width); try? await Task.sleep(for: .milliseconds(8)) }
                handleDateDrag(.ended(velocityX: velocity), width: width)
            }
            func ramp(to x: CGFloat, steps: Int) -> [CGFloat] { (1...steps).map { x * CGFloat($0) / CGFloat(steps) } }
            for pass in 0..<2 {
                if pass == 1 {
                    passReports.append(BrowseProbeRecorder.shared.report(title: "\(script) pass 1"))
                    BrowseProbeRecorder.shared.reset()
                }
                await swipe(ramp(to: -0.4 * day, steps: 40), velocity: 0)                                  // short slow drag: returns
                try? await Task.sleep(for: .milliseconds(700))
                await swipe(ramp(to: -0.7 * day, steps: 50), velocity: 0)                                  // past half: next day
                try? await Task.sleep(for: .milliseconds(800))
                await swipe(ramp(to: -0.25 * day, steps: 8), velocity: -1800)                              // hard flick
                try? await Task.sleep(for: .milliseconds(180))
                await swipe(ramp(to: -0.3 * day, steps: 10), velocity: -1600, caught: true)               // caught mid-flight, flicked on
                try? await Task.sleep(for: .milliseconds(150))
                await swipe(ramp(to: 0.35 * day, steps: 12), velocity: 1700, caught: true)                // reversal mid-flight
                try? await Task.sleep(for: .milliseconds(900))
                await swipe(ramp(to: 0.6 * day, steps: 40) + ramp(to: 0.6 * day, steps: 40).reversed().map { $0 * 0.5 }, velocity: 0)   // across the line and back
                try? await Task.sleep(for: .milliseconds(900))
            }
            while move.phase != .resting { try? await Task.sleep(for: .milliseconds(50)) }
            try? await Task.sleep(for: .milliseconds(400))
        default: break
        }
        let seconds = CFAbsoluteTimeGetCurrent() - started
        meter.stop()
        let nominal = meter.intervals.sorted().dropFirst(meter.intervals.count / 2).first ?? 16.7
        let late = meter.intervals.filter { $0 > nominal * 1.5 }.count
        let text = """
        script \(script) zoom \(String(format: "%.2f", Double(pinch.zoom))) seconds \(String(format: "%.2f", seconds))
        step cost: \(costs.summary(costs.apply))
        step interval: \(costs.summary(costs.intervals))
        display frames: \(costs.summary(meter.intervals)); late (>1.5x median) \(late) of \(meter.intervals.count)
        view build: \(pinch.buildSummary)
        partitions: background \(planner.backgroundPlans), planned in a frame \(planner.framePlans), engine runs \(planner.continuousLayoutRuns) (asked for by a frame \(planner.drawingEngineRuns)), found \(planner.partitionHits)
        day reads during script: \(model.dayReads - reads), cached \(model.cachedDays.count), selected \(model.selectedDay.daysSinceUnixEpoch - Int(Date().timeIntervalSince1970 / 86400))d from today, position \(String(format: "%.3f", move.position))
        """
        let lastTitle = passReports.isEmpty ? script : "\(script) pass 2"
        let report = passReports.joined(separator: "\n") + (passReports.isEmpty ? "" : "\n") + text + "\n" + "partitions held while a day was read \(planner.heldPartitions), axis transitions \(planner.transitionsBegun); reads dropped as stale \(model.staleReadsDropped), failed now \(model.failedDays.count)\n" + "crossfade: frames drawing a day from two decisions \(room.blendFrames), where they differed \(room.differingFrames), most things crossfaded at once \(room.crossfadedMost)\n" + BrowseProbeRecorder.shared.report(title: lastTitle)
        print("MEASURE browse-temporal\n" + report)
        if let path = Self.argument("-browse-temporal-log") { try? report.write(toFile: path, atomically: true, encoding: .utf8) }
        #endif
    }

    // MARK: Measuring by hand

    /// `-browse-temporal-probe <path>`: records from the first appearance and writes the report (cumulative) each time the days come to rest or a pinch ends,
    /// so real touches can be measured. DEBUG builds only.
    private func startProbeIfAsked() {
        // One prepared generator for the snaps (measured in 2B-2: the first `Haptics.snap()` of a launch cost 2–11 ms in the frame that crossed a day's halfway line).
        if room.haptic == nil { let haptic = UISelectionFeedbackGenerator(); haptic.prepare(); room.haptic = haptic }
        #if DEBUG
        guard let path = Self.argument("-browse-temporal-probe") else { return }
        room.probePath = path
        BrowseProbeRecorder.shared.start()
        #endif
    }

    private func writeProbeSoon() {
        #if DEBUG
        guard let path = room.probePath else { return }
        room.probeWrite?.cancel()
        room.probeWrite = Task { @MainActor [planner, model] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            let header = "selected \(model.selectedDay.daysSinceUnixEpoch); day reads \(model.dayReads); cached \(model.cachedDays.count); held partitions \(planner.heldPartitions); axis transitions \(planner.transitionsBegun); planned in a frame \(planner.framePlans), background \(planner.backgroundPlans), engine runs \(planner.continuousLayoutRuns); stale reads dropped \(model.staleReadsDropped)\n"
            try? (header + BrowseProbeRecorder.shared.report(title: "by hand")).write(toFile: path, atomically: true, encoding: .utf8)
        }
        #endif
    }

    // MARK: Planning ahead

    /// Plans the windows around the selected day off the main thread, then makes the engine's decisions for them at the rested zoom, one at a time between frames.
    private func warmAhead() async {
        let viewport = pinch.viewportHeight
        guard viewport > 1, room.width > Self.gutter else { return }
        let inputs = inputs(viewport: viewport, width: room.width)
        let selected = selectedEpoch
        let windows = [selected, selected + 1, selected - 1, selected + 2]
        planner.warm(windows: windows, inputs: inputs) { planningVersion += 1 }
        for window in windows {
            guard !Task.isCancelled else { return }
            if planner.plannedPartition(window: window, inputs: inputs) != nil, !planner.hasDecision(window: window, zoomKey: restedZoomKey) {
                BrowseProbe.measure(.warmAhead) { _ = planner.decision(window: window, zoomKey: restedZoomKey, inputs: inputs) }
            }
            await Task.yield()
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

/// What a day on screen that is not kept yet shows: that it is being read, or that it could not be read (and is tried again).
private struct DayLoadingMark: View {
    let state: AppModel.DayLoadState

    var body: some View {
        HStack(spacing: 6) {
            if state == .failed {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.caution)
                Text("불러오지 못했어요")
            } else {
                ProgressView().controlSize(.mini)
                Text("불러오는 중")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.thinMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// DEBUG: the edit probe's line (what the session sees; done and cancel are on the edit bar).
private struct EditProbeLine: View {
    let text: String
    var body: some View {
        Text(text).font(.caption2.monospacedDigit()).foregroundStyle(.purple).lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("editProbe")
            .padding(.horizontal, 12).padding(.vertical, 2)
    }
}

/// The edit session's bar: the event, its time as the draft has it (with how it moved), what is known about it elsewhere, and cancel / done. While the
/// title is renamed it rides on the keyboard: the calendars to choose from above the title being typed (the keyboard's return key is done).
private struct EditSessionBar: View {
    @Bindable var editor: FixedGridEditor
    let zone: DisplayTimeZone
    let calendars: [CalendarDescriptor]
    /// Who a new event can be with (the people known, the user left out).
    let people: [ActivityCatalog.Person]
    let isCommitting: Bool
    let rename: () -> Void
    let endRename: () -> Void
    let cancel: () -> Void
    let confirm: () -> Void

    @FocusState private var typing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if editor.isRenaming {
                CalendarChips(
                    calendars: calendars, current: editor.isNew ? editor.calendarID : editor.draft?.calendarID,
                    choose: editor.isNew ? { editor.choose($0) } : nil
                )
                if editor.isNew { MeetingChips(people: people, editor: editor) }
                HStack(spacing: 10) {
                    TextField("일정 이름", text: $editor.title)
                        .font(.body.weight(.semibold))
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.done)
                        .focused($typing)
                        .onSubmit(confirm)
                        .accessibilityIdentifier("editTitle")
                    buttons
                }
            } else {
                HStack(spacing: 10) {
                    Button(action: rename) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(editor.shownTitle).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                            Text(detail).font(.caption.monospacedDigit()).foregroundStyle(editor.conflictNote == nil ? Color.secondary : Color.orange).lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isCommitting)
                    .accessibilityElement(children: .combine)
                    .accessibilityHint("이름 바꾸기")
                    buttons
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .onChange(of: editor.isRenaming, initial: true) { _, renaming in typing = renaming }
        // A bar that appears already renaming (a new event put down) may not take the focus on its first frame: it is asked again once it is on screen.
        .task(id: editor.isRenaming) {
            guard editor.isRenaming else { return }
            try? await Task.sleep(for: .milliseconds(120))
            if editor.isRenaming, !typing { typing = true }
        }
        // The keyboard went away by itself (swiped down, another field): the renaming ends, the title kept.
        .onChange(of: typing) { _, now in if !now && editor.isRenaming { endRename() } }
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Button("취소", action: cancel)
                .buttonStyle(.bordered)
                .disabled(isCommitting)
                .accessibilityIdentifier("editCancel")
            Button(action: confirm) {
                if isCommitting { ProgressView().controlSize(.small) } else { Text("완료").bold() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isCommitting)
            .accessibilityIdentifier("editConfirm")
        }
    }

    private var detail: String {
        if let note = editor.conflictNote { return note }
        guard let draft = editor.draft else { return "" }
        let range = DraftCard.timeText(draft, zone: zone)
        if editor.isNew {
            // A new event: its time and the calendar it goes to (the name is the line above).
            return ([range] + [calendars.first { $0.id == editor.calendarID }?.title].compactMap { $0 }).joined(separator: " · ")
        }
        var moved: [String] = []
        if draft.isChanged {
            let c = draft.comparison
            if c.startChanged { moved.append("시작 " + EditSessionBarText.minutes(c.startDeltaMilliseconds)) }
            if c.endChanged { moved.append("끝 " + EditSessionBarText.minutes(c.endDeltaMilliseconds)) }
        }
        if editor.newTitle != nil { moved.append("이름 바뀜") }
        guard !moved.isEmpty else { return range }
        return range + " · " + moved.joined(separator: " · ")
    }
}

/// Who a new event is with and how many in all, in a row over the keyboard: the people known as chips to toggle (`PersonChip`, as everywhere
/// people are chosen), then the headcount with the user included, never fewer than the people chosen and the user (`CountStepper`). Saved on the event's activity once it is created, so its settlement starts from them.
private struct MeetingChips: View {
    let people: [ActivityCatalog.Person]
    @Bindable var editor: FixedGridEditor

    var body: some View {
        let least = editor.people.count + 1
        let count = max(editor.headcount ?? 0, least)
        HStack(spacing: Theme.Space.s) {
            // The count stays put at the end; only the people scroll.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Text("누구와").font(.system(.footnote, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    if people.isEmpty { Text("사람은 일정의 정산에서 추가할 수 있어요").font(.caption).foregroundStyle(Theme.textTertiary) }
                    ForEach(people) { person in
                        let chosen = editor.people.contains(person.id)
                        PersonChip(name: person.name, isSelected: chosen) {
                            if chosen { editor.people.remove(person.id) } else { editor.people.insert(person.id) }
                        }
                    }
                }
            }
            Rectangle().fill(Theme.divider).frame(width: 1, height: 20)
            CountStepper(value: count, range: least...50, compact: true, accessibilityName: "나 포함 총 인원") {
                editor.headcount = $0 <= least ? nil : $0
            }
        }
    }
}

/// The calendars an event can be in, in a row over the keyboard; the event's own is filled. A new event's calendar is chosen here (`choose`). Moving an
/// existing event to another calendar is not saved yet (its Activity is keyed by the calendar), so for one the others are shown and dimmed.
private struct CalendarChips: View {
    let calendars: [CalendarDescriptor]
    let current: CalendarID?
    /// Picks a calendar (a new event); `nil`: the chips only show which one it is in.
    var choose: ((CalendarID) -> Void)?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(calendars.filter { $0.isWritable || $0.id == current }, id: \.id) { calendar in
                    let chosen = calendar.id == current
                    let color = Color(hex: calendar.colorHex) ?? .accentColor
                    let chip = HStack(spacing: 5) {
                        Circle().fill(color).frame(width: 8, height: 8)
                        Text(calendar.title).font(.footnote.weight(chosen ? .semibold : .regular)).lineLimit(1)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(chosen ? color.opacity(0.22) : Color.secondary.opacity(0.1), in: Capsule())
                    .overlay(Capsule().stroke(chosen ? color : .clear, lineWidth: 1))
                    if let choose {
                        Button { choose(calendar.id) } label: { chip }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(chosen ? .isSelected : [])
                    } else {
                        chip
                            .opacity(chosen ? 1 : 0.45)
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(chosen ? .isSelected : [])
                            .accessibilityHint(chosen ? "" : "다른 캘린더로 옮기기는 아직 지원하지 않아요")
                    }
                }
            }
        }
        .accessibilityLabel("캘린더")
    }
}

/// What the editor says after something the person did not see happen (a refusal, a failure, an adjusted time).
private struct EditMessageView: View {
    let message: FixedGridEditor.Message
    var body: some View {
        Label(message.text, systemImage: message.isProblem ? "exclamationmark.triangle.fill" : "checkmark.circle")
            .font(.footnote)
            .foregroundStyle(message.isProblem ? Color.orange : Color.secondary)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .accessibilityAddTraits(.updatesFrequently)
    }
}

/// The event being edited, where its draft has it: outlined while unchanged (the card under it is the calendar's), filled in its calendar's colour with
/// its new time once it differs (the calendar's card is then drawn faint).
private struct DraftCard: View {
    let colorHex: String?
    /// The title as typed (a rename shows on the card while it is typed).
    let title: String
    let draft: EditDraft
    let zone: DisplayTimeZone
    let frame: CGRect
    let isChanged: Bool

    var body: some View {
        let color = Color(hex: colorHex) ?? .accentColor
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        ZStack(alignment: .topLeading) {
            if isChanged {
                shape.fill(Color(uiColor: .systemBackground))                       // opaque: what it covers does not show through
                shape.fill(color.opacity(0.85))
                if frame.height >= 18 {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.caption.weight(.semibold)).lineLimit(frame.height >= 44 ? 2 : 1)
                        if frame.height >= 34 { Text(Self.timeText(draft, zone: zone)).font(.caption2.monospacedDigit()).lineLimit(1) }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 3)
                }
            }
            shape.stroke(Color.accentColor, lineWidth: 2)
        }
        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
        .clipped()
        .offset(x: frame.minX, y: frame.minY)
        .accessibilityHidden(true)
    }

    /// "오후 2:00 – 3:15" in the grid's zone.
    @MainActor static func timeText(_ draft: EditDraft, zone: DisplayTimeZone) -> String {
        clock(draft.startDate, zone: zone) + " – " + clock(draft.endDate, zone: zone)
    }

    /// "오후 2:00" in the grid's zone.
    @MainActor static func clock(_ date: Date, zone: DisplayTimeZone) -> String { formatter(zone).string(from: date) }

    @MainActor private static var formatters: [String: DateFormatter] = [:]
    @MainActor private static func formatter(_ zone: DisplayTimeZone) -> DateFormatter {
        if let known = formatters[zone.identifier] { return known }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.timeZone = TimeZone(identifier: zone.identifier)
        formatter.dateFormat = "a h:mm"
        formatters[zone.identifier] = formatter
        return formatter
    }
}

/// The transaction a long press carries: its name and amount, and the event it would go into.
private struct CarriedTransactionCard: View {
    let title: String?
    let amount: Money
    let flow: TransactionFlow
    /// The event it goes into if put down now (`nil`: nowhere).
    let into: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title ?? "거래").font(.caption.weight(.semibold)).lineLimit(1)
                Text((flow == .refund ? "+" : "") + Formatting.money(amount.minorUnits, currency: amount.currency)).font(.caption.monospacedDigit())
            }
            Text(into.map { "→ " + $0 } ?? "일정 위에 놓아 주세요").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
        .accessibilityHidden(true)
    }
}

/// Where the carried new event would be put down: a dashed outline in the calendar's colour, nothing written in it.
private struct DropOutline: View {
    let colorHex: String?
    let frame: CGRect

    var body: some View {
        let color = Color(hex: colorHex) ?? .accentColor
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(color, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
            .animation(.easeOut(duration: 0.12), value: frame)
            .accessibilityHidden(true)
    }
}

/// The new event a long press carries, in the hand: a lifted card of the calendar's colour with its name and the time it would be put down at.
private struct CarriedCard: View {
    let colorHex: String?
    let title: String
    let frame: CGRect
    let time: String

    var body: some View {
        let color = Color(hex: colorHex) ?? .accentColor
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        ZStack(alignment: .topLeading) {
            shape.fill(Color(uiColor: .systemBackground))
            shape.fill(color.opacity(0.3))
            Rectangle().fill(color).frame(width: 3)
            if frame.height >= 18 {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.caption.weight(.semibold)).lineLimit(1)
                    if frame.height >= 34 { Text(time).font(.caption2.monospacedDigit()).lineLimit(1) }
                }
                .foregroundStyle(.primary)
                .padding(.leading, 8).padding(.trailing, 5).padding(.vertical, 3)
            }
        }
        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
        .clipShape(shape)
        .shadow(color: .black.opacity(0.22), radius: 8, y: 4)
        .offset(x: frame.minX, y: frame.minY)
        .accessibilityHidden(true)
    }
}

/// A time written on the hour axis at a height (over the hour labels there), with a line from the axis to the card: where a new event or a dragged edge is.
private struct GutterTimeMark: View {
    let text: String
    let y: CGFloat
    let gutter: CGFloat
    /// Where the line ends (the card's left edge).
    let lineTo: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.accentColor).frame(width: max(0, lineTo - (gutter - 8)), height: 1)
                .offset(x: gutter - 8, y: y - 0.5)
            Text(text)
                .font(.caption2.weight(.semibold).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.6)
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 3).padding(.vertical, 1)
                .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .frame(width: gutter - 6, alignment: .trailing)
                .frame(height: 16)
                .offset(y: y - 8)
        }
        .accessibilityHidden(true)
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
            presentation: item.presentation, scale: scale, zoneIdentifier: zoneIdentifier,
            endIsCovered: overlays.contains { $0.intersects(CGRect(x: frame.maxX - 48, y: frame.maxY - 16, width: 48, height: 16)) },
            startIsCovered: overlays.contains { $0.intersects(CGRect(x: frame.maxX - 48, y: frame.minY + 3, width: 48, height: 11)) },
            summaryIsCovered: overlays.contains { $0.intersects(CGRect(x: frame.minX + 6, y: frame.maxY - 26, width: min(frame.width - 12, 150), height: 22)) },
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
    private var rail: CGFloat { gutter - 8 }

    var body: some View {
        let metrics = HourAxis.Metrics(textScale: scale)
        // The hours with a line across the days come first: theirs are the labels that keep their room. Between days the ends are laid out apart and blended.
        let states = HourAxis.fixedGridLayout(partition: partition, metrics: metrics)
        ZStack(alignment: .topLeading) {
            ForEach(0..<partition.slotCount, id: \.self) { slot in
                Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: max(0, width - gutter), height: 0.5)
                    .offset(x: gutter, y: partition.top(ofSlot: slot))
            }
            ForEach(states, id: \.hour) { state in
                if state.labelOpacity > 0.003 {
                    // Every hour is written the same, as Apple's Calendar writes it: period and hour on one line, centred on the line it belongs to
                    // (Hans picked this over four other axes, 2026-10-24). Which hours have room is still decided by `HourAxis.layout`.
                    AxisHourText(hour: state.hour, size: metrics.labelFontSize * 0.95)
                        .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .frame(width: rail - 4, height: metrics.labelHeight, alignment: .trailing)
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

/// An hour on the axis as Apple's Calendar writes it: the hour's number a size larger than the small "오전" and "시" around it. Midnight and noon keep their names.
private struct AxisHourText: View {
    let hour: Int
    let size: CGFloat

    var body: some View {
        if !CardStyle.current.isApple || hour % 12 == 0 {
            Text(Formatting.axisHourLabel(hour)).font(.system(size: size).monospacedDigit())
        } else {
            (Text(hour < 12 ? "오전 " : "오후 ").font(.system(size: size * 0.74))
                + Text("\(hour % 12)").font(.system(size: size * 1.0, weight: .medium).monospacedDigit())
                + Text("시").font(.system(size: size * 0.74)))
        }
    }
}
