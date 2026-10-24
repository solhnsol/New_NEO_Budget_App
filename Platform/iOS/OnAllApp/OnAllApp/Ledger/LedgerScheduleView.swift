import NEOBudgetCalendar
import NEOBudgetCore
import SwiftUI

/// The ledger tab read like the calendar: a week strip with each day's spending, and under it the chosen day, where an activity is one card
/// holding the transactions that went to it and every other transaction is a plain line.
struct LedgerScheduleView: View {
    let sections: [LedgerDaySection]
    let model: AppModel
    @State private var selected: LocalDate
    @State private var showsPicker = false

    init(sections: [LedgerDaySection], model: AppModel) {
        self.sections = sections
        self.model = model
        _selected = State(initialValue: model.dayZone.localDate(of: Int64(Date().timeIntervalSince1970 * 1_000)))
    }

    private var zone: DisplayTimeZone { model.dayZone }
    private var today: LocalDate { zone.localDate(of: Int64(Date().timeIntervalSince1970 * 1_000)) }
    private var weekStart: LocalDate { selected.adding(days: -selected.weekday) }
    private var bySection: [LocalDate: LedgerDaySection] { Dictionary(uniqueKeysWithValues: sections.map { ($0.day, $0) }) }

    var body: some View {
        let lookup = bySection
        let items = lookup[selected].map { LedgerSchedule.items($0, zone: zone) } ?? []
        VStack(spacing: 0) {
            header
            weekStrip(lookup)
            ScrollView {
                LazyVStack(spacing: Theme.Space.s) {
                    if items.isEmpty {
                        Text("이날은 거래가 없어요").font(Theme.Typo.label).foregroundStyle(Theme.textTertiary).padding(.top, Theme.Space.xxl)
                    }
                    ForEach(items) { item in
                        switch item {
                        case let .activity(group): ActivityCard(group: group, zone: zone)
                        case let .loose(entry): LooseLine(entry: entry, zone: zone)
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.l)
                .padding(.vertical, Theme.Space.m)
            }
        }
        .background(Theme.background)
        .sheet(isPresented: $showsPicker) {
            DatePickerSheet(selected: $selected, zone: zone)
        }
    }

    private var header: some View {
        HStack {
            Button { selected = selected.adding(days: -7) } label: { Image(systemName: "chevron.left") }
            Spacer()
            Button { showsPicker = true } label: {
                Text(Formatting.dayRangeTitle(weekStart, weekStart.adding(days: 6))).font(Theme.Typo.title).foregroundStyle(Theme.textPrimary)
            }
            Spacer()
            Button { selected = selected.adding(days: 7) } label: { Image(systemName: "chevron.right") }
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, Theme.Space.s)
    }

    private func weekStrip(_ lookup: [LocalDate: LedgerDaySection]) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { column in
                let day = weekStart.adding(days: column)
                Button { selected = day } label: {
                    VStack(spacing: Theme.Space.xs) {
                        Text(Formatting.weekdayShort(day)).font(.caption2).foregroundStyle(Theme.textTertiary)
                        Text("\(day.day)").font(.system(.title3, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(day == today ? Theme.accent : Theme.textPrimary)
                        Text(LedgerSchedule.compactAmount(LedgerSchedule.dayTotal(lookup[day])))
                            .font(.caption2).monospacedDigit().foregroundStyle(Theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, Theme.Space.s)
                    .background(day == selected ? Theme.fill : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.button))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Theme.Space.xs)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .padding(.horizontal, Theme.Space.l)
        .padding(.bottom, Theme.Space.xs)
    }

    private struct DatePickerSheet: View {
        @Binding var selected: LocalDate
        let zone: DisplayTimeZone
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            let binding = Binding<Date>(
                get: { Date(timeIntervalSince1970: Double(zone.instant(of: selected, minuteOfDay: 720)) / 1_000) },
                set: { selected = zone.localDate(of: Int64($0.timeIntervalSince1970 * 1_000)); dismiss() }
            )
            DatePicker("날짜", selection: binding, displayedComponents: .date)
                .datePickerStyle(.graphical).padding().presentationDetents([.medium])
        }
    }
}

/// An activity with the transactions that went to it, as one white card.
private struct ActivityCard: View {
    let group: LedgerScheduleItem.Group
    let zone: DisplayTimeZone

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(group.title).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer()
                Text(Formatting.money(group.totalMinorUnits, currency: group.currency)).font(Theme.Typo.amount).foregroundStyle(Theme.textPrimary)
            }
            if let time = timeText { Text(time).font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary) }
            ForEach(group.entries) { entry in
                NavigationLink { TransactionDetailView(entry: entry, zone: zone) } label: {
                    LedgerRow(entry: entry, zoneIdentifier: zone.identifier)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    private var timeText: String? {
        switch group.time {
        case let .timed(range)?: Formatting.timeRange(range.startUnixMilliseconds, range.endUnixMilliseconds, zoneIdentifier: zone.identifier)
        case .allDay?: "하루 종일"
        case nil: nil
        }
    }
}

/// A transaction no activity holds: one line on the grey background, like a loose transaction on the calendar.
private struct LooseLine: View {
    let entry: LedgerListEntry
    let zone: DisplayTimeZone

    var body: some View {
        NavigationLink { TransactionDetailView(entry: entry, zone: zone) } label: {
            LedgerRow(entry: entry, zoneIdentifier: zone.identifier)
                .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.s)
        }
        .buttonStyle(.plain)
    }
}
