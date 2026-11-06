import NEOBudgetCalendar
import NEOBudgetCore
import SwiftUI

/// 일정: a full screen (not a sheet) for choosing the event the picked transactions go into. Any event on any day can be chosen: the week strip
/// moves day by day, the arrows move by month, and the grip under it unfolds the month. 확인 stays off until something is chosen; 취소 goes back to
/// the selection untouched. "새 일정 만들기" opens a small sheet and comes back with the new event chosen; "일정 없음으로" takes them out of every event.
struct LedgerEventPicker: View {
    enum Choice: Equatable {
        case event(CalendarEventKey)
        case none
    }

    private struct Item: Identifiable {
        let key: CalendarEventKey
        let title: String
        let time: String
        let start: Int64
        let color: Color
        var id: CalendarEventKey { key }
    }

    private struct LoadKey: Equatable {
        let first: LocalDate
        let count: Int
        let generation: Int
        let tick: Int
    }

    let model: AppModel
    let entries: [LedgerListEntry]
    /// Called once the transactions have been moved, before the screen closes.
    let onApplied: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var day: LocalDate
    @State private var isMonthOpen = false
    @State private var timelines: [LocalDate: DayTimeline] = [:]
    @State private var choice: Choice?
    @State private var isCreating = false
    @State private var failure: String?
    @State private var tick = 0

    init(model: AppModel, entries: [LedgerListEntry], onApplied: @escaping () -> Void) {
        self.model = model
        self.entries = entries
        self.onApplied = onApplied
        let first = entries.map(\.transaction.occurredAtUnixMilliseconds).min() ?? model.nowMilliseconds
        _day = State(initialValue: model.dayZone.localDate(of: first))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(spacing: Theme.Space.m) {
                    calendarCard
                    dayHeader
                    VStack(spacing: Theme.Space.s) {
                        ForEach(items) { item in card(item) }
                    }
                    optionsCard
                    if let failure {
                        Text(failure).font(Theme.Typo.label).foregroundStyle(Theme.danger)
                    }
                }
                .padding(.horizontal, Theme.cardMargin)
                .padding(.bottom, Theme.Space.xxl)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .task(id: LoadKey(first: visibleDays.first ?? day, count: visibleDays.count, generation: model.dataGeneration, tick: tick)) {
            let read = await model.readDays(visibleDays)
            timelines = Dictionary(read.compactMap { stripDay in stripDay.timeline.map { (stripDay.day, $0) } }, uniquingKeysWith: { $1 })
        }
        .sheet(isPresented: $isCreating) {
            LedgerNewEventSheet(model: model, day: day, suggestedStart: suggestedStart) { key, created in
                day = model.dayZone.localDate(of: created)
                choice = .event(key)
                tick += 1
            }
            .onAllSheet(detents: [.height(320)])
        }
    }

    // MARK: Pieces

    private var topBar: some View {
        HStack {
            Button("취소") { dismiss() }.foregroundStyle(Theme.textSecondary)
            Spacer()
            VStack(spacing: 2) {
                Text("일정").font(Theme.Typo.sheetTitle).foregroundStyle(Theme.textPrimary)
                Text(summary).font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            Button("확인") { Task { await confirm() } }
                .fontWeight(.semibold)
                .foregroundStyle(choice == nil ? Theme.disabled : Theme.accent)
                .disabled(choice == nil)
        }
        .padding(.horizontal, Theme.cardMargin)
        .frame(height: 56)
    }

    private var summary: String {
        let total = entries.reduce(Int64(0)) { $0 + $1.signedNetMinorUnits }
        return "선택한 \(entries.count)건 · " + Formatting.money(total, currency: entries.first?.transaction.amount.currency ?? "KRW")
    }

    private var calendarCard: some View {
        VStack(spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.l) {
                Spacer()
                Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("이전 달")
                Text("\(day.month)월").font(Theme.Typo.section).foregroundStyle(Theme.textPrimary).frame(minWidth: 56)
                Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("다음 달")
                Spacer()
            }
            .foregroundStyle(Theme.textSecondary)
            HStack(spacing: 0) {
                ForEach(["일", "월", "화", "수", "목", "금", "토"], id: \.self) { name in
                    Text(name).font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary).frame(maxWidth: .infinity)
                }
            }
            let weeks = stride(from: 0, to: visibleDays.count, by: 7).map { Array(visibleDays[$0..<$0 + 7]) }
            ForEach(weeks, id: \.first) { week in
                HStack(spacing: 0) { ForEach(week, id: \.self) { cell($0) } }
            }
            Button {
                withAnimation(Theme.Motion.monthUnfold) { isMonthOpen.toggle() }
            } label: {
                Capsule().fill(Theme.disabled).frame(width: 36, height: 4).frame(maxWidth: .infinity, minHeight: 20)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isMonthOpen ? "한 주만 보기" : "한 달 펼치기")
        }
        .padding(Theme.Space.m)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private func cell(_ date: LocalDate) -> some View {
        let isChosen = date == day
        let inMonth = date.month == day.month
        return Button { day = date } label: {
            VStack(spacing: 3) {
                Text("\(date.day)").font(.system(size: 15, weight: isChosen ? .semibold : .regular))
                    .foregroundStyle(isChosen ? Theme.accentStrong : (isMonthOpen && !inMonth ? Theme.textTertiary : Theme.textPrimary))
                    .frame(width: 34, height: 34)
                    .background(isChosen ? Theme.accentSoft : .clear, in: Circle())
                HStack(spacing: 2) {
                    ForEach(Array(dotColors(date).enumerated()), id: \.offset) { _, color in Circle().fill(color).frame(width: 4, height: 4) }
                }
                .frame(height: 4)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Formatting.dayTitle(date))
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    private var dayHeader: some View {
        HStack {
            Text("\(day.day)일 \(Formatting.weekdayShort(day))요일").font(Theme.Typo.section).foregroundStyle(Theme.textPrimary)
            Spacer()
            Text("일정 \(items.count)개").font(Theme.Typo.label).foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, Theme.Space.xs)
        .padding(.top, Theme.Space.s)
    }

    private func card(_ item: Item) -> some View {
        let isChosen = choice == .event(item.key)
        return Button { choice = .event(item.key) } label: {
            HStack {
                Text(item.title).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer(minLength: Theme.Space.s)
                Text(item.time).font(Theme.Typo.label).foregroundStyle(Theme.textTertiary)
                checkmark(isChosen)
            }
            .padding(.horizontal, Theme.Space.l)
            .frame(minHeight: 56)
            .background(item.color.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.smallButton, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.smallButton, style: .continuous).stroke(isChosen ? Theme.accent : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    private func checkmark(_ on: Bool) -> some View {
        ZStack {
            Circle().fill(on ? Theme.accent : .clear)
            Circle().stroke(on ? Theme.accent : Theme.disabled, lineWidth: 1.5)
            if on { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white) }
        }
        .frame(width: 22, height: 22)
    }

    private var optionsCard: some View {
        VStack(spacing: 0) {
            Button { isCreating = true } label: { optionRow("plus", "새 일정 만들기", on: false) }
            Divider().overlay(Theme.divider)
            Button { choice = .none } label: { optionRow("nosign", "일정 없음으로", on: choice == .none) }
        }
        .buttonStyle(.onAllRow)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private func optionRow(_ symbol: String, _ title: String, on: Bool) -> some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: symbol).foregroundStyle(Theme.textSecondary).frame(width: 24)
            Text(title).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary)
            Spacer()
            if on { checkmark(true) }
        }
        .padding(.horizontal, Theme.Space.l)
        .frame(minHeight: Theme.rowHeight)
        .contentShape(Rectangle())
    }

    // MARK: Data

    /// The days drawn: the week of the chosen day, or the whole month in weeks.
    private var visibleDays: [LocalDate] {
        let anchor: LocalDate
        let count: Int
        if isMonthOpen {
            let first = (try? LocalDate(year: day.year, month: day.month, day: 1)) ?? day
            anchor = first.adding(days: -first.weekday)
            let last = first.adding(days: LocalDate.daysInMonth(year: day.year, month: day.month) - 1)
            count = ((last.daysSinceUnixEpoch - anchor.daysSinceUnixEpoch) / 7 + 1) * 7
        } else {
            anchor = day.adding(days: -day.weekday)
            count = 7
        }
        return (0..<count).map { anchor.adding(days: $0) }
    }

    private var items: [Item] {
        guard let timeline = timelines[day] else { return [] }
        let zone = model.dayZone.identifier
        let timed = timeline.blocks.filter { $0.revisionToken != nil }.map {
            Item(key: $0.eventKey, title: $0.title, time: Formatting.timeRange($0.startUnixMilliseconds, $0.endUnixMilliseconds, zoneIdentifier: zone),
                 start: $0.startUnixMilliseconds, color: Color(hex: $0.calendarColorHex) ?? Theme.accent)
        }
        let allDay = timeline.allDay.map {
            Item(key: $0.eventKey, title: $0.title, time: "종일", start: timeline.dayStartUnixMilliseconds, color: Color(hex: $0.calendarColorHex) ?? Theme.accent)
        }
        return (allDay + timed.sorted { $0.start < $1.start }).sorted { $0.start < $1.start }
    }

    private func dotColors(_ date: LocalDate) -> [Color] {
        guard let timeline = timelines[date] else { return [] }
        let hexes = timeline.allDay.map(\.calendarColorHex) + timeline.blocks.map(\.calendarColorHex)
        return hexes.prefix(3).map { Color(hex: $0) ?? Theme.accent }
    }

    /// Where a new event starts: the first picked transaction's hour when the chosen day is its day, else noon.
    private var suggestedStart: Int64 {
        let zone = model.dayZone
        if let first = entries.map(\.transaction.occurredAtUnixMilliseconds).min(), zone.localDate(of: first) == day {
            return zone.startOfDay(day) + (first - zone.startOfDay(day)) / 3_600_000 * 3_600_000
        }
        return zone.instant(of: day, minuteOfDay: 12 * 60)
    }

    private func shiftMonth(_ delta: Int) {
        var year = day.year, month = day.month + delta
        if month > 12 { month = 1; year += 1 } else if month < 1 { month = 12; year -= 1 }
        let number = min(day.day, LocalDate.daysInMonth(year: year, month: month))
        if let moved = try? LocalDate(year: year, month: month, day: number) { day = moved }
    }

    private func confirm() async {
        guard let choice else { return }
        for entry in entries {
            let command: CalendarCommand
            switch choice {
            case let .event(key): command = ActivityEditing.link(entry.id, event: key, now: model.nowMilliseconds)
            case .none: command = ActivityEditing.unlink(entry.id, now: model.nowMilliseconds)
            }
            if case let .rejected(reason)? = await model.perform(command) {
                failure = "옮기지 못했어요. (\(reason))"
                return
            }
        }
        onApplied()
        dismiss()
    }
}

/// 새 일정 만들기: a small sheet with a title, a start time and a calendar. Saving makes the event and hands it back chosen.
private struct LedgerNewEventSheet: View {
    let model: AppModel
    let day: LocalDate
    let suggestedStart: Int64
    let created: (CalendarEventKey, Int64) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var start: Date
    @State private var calendarID: CalendarID?
    @State private var failure: String?
    @FocusState private var focused: Bool

    init(model: AppModel, day: LocalDate, suggestedStart: Int64, created: @escaping (CalendarEventKey, Int64) -> Void) {
        self.model = model
        self.day = day
        self.suggestedStart = suggestedStart
        self.created = created
        _start = State(initialValue: Date(timeIntervalSince1970: Double(suggestedStart) / 1_000))
        _calendarID = State(initialValue: model.calendars.first(where: \.isWritable)?.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack {
                TextField("제목", text: $title).font(Theme.Typo.sheetTitle).focused($focused).submitLabel(.done)
                Button("저장") { Task { await save() } }
                    .buttonStyle(PrimaryButtonStyle(height: Theme.smallButtonHeight)).frame(width: 64)
                    .disabled(ActivityEditing.cleanName(title) == nil || calendarID == nil)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.s) {
                    ForEach(model.calendars.filter(\.isWritable), id: \.id) { calendar in
                        let isChosen = calendar.id == calendarID
                        Button { calendarID = calendar.id } label: {
                            HStack(spacing: 6) {
                                Circle().fill(Color(hex: calendar.colorHex) ?? Theme.accent).frame(width: 8, height: 8)
                                Text(calendar.title).font(Theme.Typo.chip)
                            }
                            .foregroundStyle(isChosen ? Theme.accentStrong : Theme.textSecondary)
                            .padding(.horizontal, Theme.Space.m).frame(height: Theme.chipHeight)
                            .background(isChosen ? Theme.accentSoft : Theme.fill, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            DatePicker("시작", selection: $start, displayedComponents: [.date, .hourAndMinute])
                .environment(\.timeZone, TimeZone(identifier: model.dayZone.identifier) ?? .current)
                .font(Theme.Typo.label).foregroundStyle(Theme.textSecondary)
            if let failure { Text(failure).font(Theme.Typo.caption).foregroundStyle(Theme.danger) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.top, Theme.Space.xl)
        .onAppear { focused = true }
    }

    private func save() async {
        guard let name = ActivityEditing.cleanName(title), let calendarID else { return }
        let from = Int64(start.timeIntervalSince1970 * 1_000)
        guard let range = try? TimedRange(startUnixMilliseconds: from, endUnixMilliseconds: from + 3_600_000) else { return }
        let draft = CalendarEventDraft(calendarID: calendarID, title: name, time: .timed(range), timeZoneIdentifier: model.dayZone.identifier)
        switch await model.perform(.createEvent(CreateEventInput(draft: draft))) {
        case let .applied(applied)?, let .partiallyApplied(applied, _)?:
            if let key = applied.event?.key { created(key, from); dismiss() } else { failure = "만들었지만 선택하지 못했어요. 목록에서 골라 주세요." }
        default:
            failure = "일정을 만들지 못했어요. 다시 시도해 주세요."
        }
    }
}
