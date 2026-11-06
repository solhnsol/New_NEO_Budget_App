import NEOBudgetCalendar
import NEOBudgetCore
import SwiftUI

/// The calendar's list style (design ledger-v20 ①②): the selected day's title, then its events and transactions in the order they happen. An event is
/// a box tinted with its colour that holds the transactions that went to it (a name and a time only, once it has begun; a larger title when it is
/// still to come); a transaction no event holds is a plain row. It reads the same `DayTimeline` as the rail.
struct DayListView: View {
    let model: AppModel
    /// The day sits under the top chrome (month, week strip); this is how far its content starts below the top of the screen.
    var topInset: CGFloat = 0
    let onSelect: (TimelineSelection) -> Void
    let onOpenTransaction: (LedgerEntryID) -> Void

    @State private var timeline: DayTimeline?

    var body: some View {
        let day = model.selectedDay
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                let plan = timeline.map { Plan($0, nowMilliseconds: model.nowMilliseconds) }
                HStack(alignment: .firstTextBaseline) {
                    Text("\(day.day)일 \(Formatting.weekdayShort(day))요일").font(Theme.Typo.section).foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 0)
                    if let plan, plan.eventCount > 0, plan.rowCount == 0 || plan.futureOnly {
                        Text("일정 \(plan.eventCount)개").font(Theme.Typo.label).foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(.horizontal, 28).padding(.top, 8).padding(.bottom, 8)
                if let plan {
                    ForEach(plan.items) { item in
                        switch item.kind {
                        case let .row(row): TransactionRow(row: row, inEvent: false).listTap { onOpenTransaction(row.id) }
                        case let .event(block, rows, isFuture):
                            EventBox(block: block, rows: rows, isFuture: isFuture, onSelect: { onSelect(.event(block)) }, onOpenTransaction: onOpenTransaction)
                        }
                    }
                    if plan.items.isEmpty {
                        Text("일정과 거래가 없어요").font(Theme.Typo.label).foregroundStyle(Theme.textTertiary).padding(.horizontal, 28).padding(.vertical, Theme.Space.s)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 48)
                }
            }
            .padding(.bottom, Theme.Space.xl)
        }
        .scrollBounceBehavior(.basedOnSize)
        .contentMargins(.top, topInset, for: .scrollContent)
        .contentMargins(.top, topInset, for: .scrollIndicators)
        .ignoresSafeArea(edges: .top)
        .task(id: Key(day: day, generation: model.dataGeneration)) {
            if let read = await model.readDays([day]).first?.timeline { timeline = read }
        }
    }

    private struct Key: Hashable { let day: LocalDate; let generation: Int }

    /// What the list draws for one day, in time order.
    struct Plan {
        struct Row: Identifiable {
            let id: LedgerEntryID
            let minute: Int
            let title: String
            let category: CanonicalCategoryID?
            let amountText: String
            let isIncoming: Bool
        }

        struct Item: Identifiable {
            enum Kind { case row(Row), event(EventBlock, [Row], isFuture: Bool) }
            let id: String
            let minute: Int
            let kind: Kind
        }

        let items: [Item]
        let eventCount: Int
        let rowCount: Int
        /// Nothing of the day has happened yet.
        let futureOnly: Bool

        init(_ timeline: DayTimeline, nowMilliseconds: Int64) {
            let raw = (nowMilliseconds - timeline.dayStartUnixMilliseconds) / 60_000
            let now = Int(max(-1, min(Int64(timeline.totalMinutes + 1), raw)))
            func row(_ id: LedgerEntryID, _ minute: Int, _ title: String?, _ category: CanonicalCategoryID?, _ money: Money, incoming: Bool) -> Row {
                Row(id: id, minute: minute, title: title ?? "거래", category: category, amountText: RailPlan.railAmount(Formatting.money(money.minorUnits, currency: money.currency), incoming: incoming), isIncoming: incoming)
            }
            let blocks = timeline.blocks.sorted { ($0.displayStartMinute, $0.id.rawValue) < ($1.displayStartMinute, $1.id.rawValue) }
            let marked = Set(timeline.markers.map(\.transactionID))
            var items: [Item] = timeline.markers.map { marker in
                let loose = row(marker.transactionID, marker.positionMinute, marker.title, marker.categoryID, marker.amount, incoming: marker.flow == .refund)
                return Item(id: "m/" + marker.transactionID.rawValue, minute: marker.positionMinute, kind: .row(loose))
            }
            var rowCount = items.count
            for block in blocks {
                // A transaction wholly inside an event has no marker of its own; it is drawn from the event's allocations.
                let inside: [Row] = block.allocations.filter { $0.occursOnSelectedDay && !marked.contains($0.transactionID) }.map { item in
                    let minute = Int(max(0, min(Int64(timeline.totalMinutes - 1), (item.occurredAtUnixMilliseconds - timeline.dayStartUnixMilliseconds) / 60_000)))
                    return row(item.transactionID, minute, item.title, item.categoryID, item.transactionAmount, incoming: item.flow == .refund)
                }.sorted { ($0.minute, $0.id.rawValue) < ($1.minute, $1.id.rawValue) }
                rowCount += inside.count
                items.append(Item(id: "e/" + block.id.rawValue, minute: block.displayStartMinute, kind: .event(block, inside, isFuture: block.displayStartMinute >= now)))
            }
            self.items = items.sorted { ($0.minute, $0.id) < ($1.minute, $1.id) }
            self.eventCount = blocks.count
            self.rowCount = rowCount
            self.futureOnly = !blocks.isEmpty && rowCount == 0 && blocks.allSatisfy { $0.displayStartMinute >= now }
        }
    }
}

private func clockText(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }

private extension View {
    /// A row that opens on a tap: a tap gesture, not a `Button`, so a swipe that starts on it never opens it.
    func listTap(_ action: @escaping () -> Void) -> some View {
        contentShape(Rectangle()).onTapGesture(perform: action).accessibilityAddTraits(.isButton)
    }
}

/// An event as a box in its colour: a small name and time while it is going or done, a title and time when it is still to come; its transactions under it.
private struct EventBox: View {
    let block: EventBlock
    let rows: [DayListView.Plan.Row]
    let isFuture: Bool
    let onSelect: () -> Void
    let onOpenTransaction: (LedgerEntryID) -> Void

    var body: some View {
        let color = Color(hex: block.calendarColorHex) ?? Theme.accent
        let range = clockText(block.displayStartMinute) + " – " + clockText(block.displayEndMinute)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                if isFuture {
                    Text(block.title).font(Theme.Typo.rowTitle.weight(.semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Spacer(minLength: Theme.Space.s)
                    Text(range).font(Theme.Typo.label).foregroundStyle(Theme.textSecondary)
                } else {
                    Text(block.title).font(.onAll(size: 13, weight: .medium)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    Spacer(minLength: Theme.Space.s)
                    Text(range).font(.onAll(size: 12)).foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, Theme.Space.l).padding(.top, isFuture ? 14 : 12).padding(.bottom, rows.isEmpty && !isFuture ? 12 : 2)
            .listTap(onSelect)
            ForEach(rows) { row in
                DayListView.TransactionRow(row: row, inEvent: true).listTap { onOpenTransaction(row.id) }
            }
        }
        .padding(.bottom, rows.isEmpty ? (isFuture ? 12 : 0) : Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .padding(.horizontal, Theme.Space.m).padding(.top, Theme.Space.s)
    }
}

extension DayListView {
    /// One transaction: its category tile, name and time, the amount at the right (spent is blue, money in is red). Inside an event the tile is white.
    struct TransactionRow: View {
        let row: Plan.Row
        let inEvent: Bool

        var body: some View {
            let tile = CategoryIcon.tile(for: row.category)
            HStack(spacing: Theme.Space.m) {
                LineIcon(name: tile.icon, size: 20).foregroundStyle(Theme.textSecondary)
                    .frame(width: 40, height: 40).background(inEvent ? Theme.surface : tile.tint, in: Circle())
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.title).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text(clockText(row.minute)).font(Theme.Typo.label).foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: Theme.Space.s)
                Text(row.amountText).font(row.isIncoming ? Font.onAll(size: 16, weight: .semibold).monospacedDigit() : Theme.Typo.amount)
                    .foregroundStyle(Theme.amountColor(isIncoming: row.isIncoming)).lineLimit(1).fixedSize()
            }
            .padding(.horizontal, inEvent ? Theme.Space.l : 28).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(row.title), \(row.amountText), \(clockText(row.minute))")
        }
    }
}
