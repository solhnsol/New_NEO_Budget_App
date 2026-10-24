import NEOBudgetCalendar
import NEOBudgetCore
import SwiftUI

/// The calendar's list style: the two days on screen as cards. An event is one card with its time, what was spent on it, and the transactions that
/// went to it inside; all-day events and transactions no event holds are single lines. It reads the same `DayTimeline` as the grid.
struct DayListView: View {
    let model: AppModel
    /// How far from the top of the screen the list starts: it runs under the translucent top bar, so what scrolls up shows through it.
    var topInset: CGFloat = 0
    let onSelect: (TimelineSelection) -> Void
    let onOpenTransaction: (LedgerEntryID) -> Void
    /// A sideways swipe on the list: -1 for the previous day, +1 for the next.
    let onMoveDay: (Int) -> Void

    var body: some View {
        let zone = model.dayZone
        // The same two days as the grid's two columns (and the header's range): the selected day and the one after it.
        let days = [model.selectedDay, model.selectedDay.adding(days: 1)]
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.s) {
                ForEach(days, id: \.self) { day in
                    Text(Formatting.dayTitle(day)).font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(day == model.today ? Theme.accent : Theme.textSecondary)
                        .padding(.top, Theme.Space.s)
                    if let timeline = model.cachedTimeline(for: day) {
                        let plan = DayListPlan.make(timeline)
                        if plan.items.isEmpty {
                            Text("일정과 거래가 없어요").font(Theme.Typo.label).foregroundStyle(Theme.textTertiary).padding(.vertical, Theme.Space.s)
                        }
                        ForEach(plan.items) { item in
                            switch item {
                            case let .allDay(allDay): AllDayLine(item: allDay) { onSelect(.allDay(allDay)) }
                            case let .event(block):
                                EventCard(block: block, model: model, zone: zone, onSelect: { onSelect(.event(block)) }, onOpenTransaction: onOpenTransaction)
                            case let .marker(marker):
                                DayListTransactionLine(
                                    title: model.transactionOverrides[marker.transactionID]?.title ?? marker.title ?? "거래",
                                    detail: Formatting.time(marker.occurredAtUnixMilliseconds, zoneIdentifier: zone.identifier),
                                    amount: marker.amount, isRefund: marker.flow == .refund,
                                    category: model.transactionOverrides[marker.transactionID]?.category ?? marker.categoryID
                                ) { onOpenTransaction(marker.transactionID) }
                            }
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, Theme.Space.l)
                    }
                }
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.s)
        }
        .contentMargins(.top, topInset, for: .scrollContent)
        .contentMargins(.top, topInset, for: .scrollIndicators)
        .ignoresSafeArea(edges: .top)
        .simultaneousGesture(
            DragGesture(minimumDistance: 30).onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                onMoveDay(value.translation.width < 0 ? 1 : -1)
            }
        )
    }
}

private struct AllDayLine: View {
    let item: AllDayItem
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Theme.Space.s) {
                Circle().fill(Color(hex: item.calendarColorHex) ?? Theme.accent).frame(width: 8, height: 8)
                Text(item.title).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text("하루 종일").font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary)
                Spacer()
            }
            .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.s)
        }
        .buttonStyle(.plain)
    }
}

/// An event as one white card with a bar in its calendar's colour, what was spent on it, and the transactions that went to it.
private struct EventCard: View {
    let block: EventBlock
    let model: AppModel
    let zone: DisplayTimeZone
    let onSelect: () -> Void
    let onOpenTransaction: (LedgerEntryID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(block.title).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Spacer()
                        if let spend = block.allocatedSpend.first {
                            Text(Formatting.aggregate(spend)).font(Theme.Typo.amount).foregroundStyle(Theme.textPrimary)
                        }
                    }
                    Text(Formatting.timeRange(block.startUnixMilliseconds, block.endUnixMilliseconds, zoneIdentifier: zone.identifier))
                        .font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            ForEach(block.allocations, id: \.allocationID) { item in
                DayListTransactionLine(
                    title: model.transactionOverrides[item.transactionID]?.title ?? item.title ?? "거래",
                    detail: item.occursOnSelectedDay ? Formatting.time(item.occurredAtUnixMilliseconds, zoneIdentifier: zone.identifier)
                        : Formatting.shortDate(item.occurredAtUnixMilliseconds, zoneIdentifier: zone.identifier),
                    amountText: Formatting.knowledge(item.allocatedAmount, currency: item.transactionAmount.currency),
                    isRefund: item.flow == .refund,
                    category: model.transactionOverrides[item.transactionID]?.category ?? item.categoryID
                ) { onOpenTransaction(item.transactionID) }
            }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(alignment: .leading) {
            Capsule().fill(Color(hex: block.calendarColorHex) ?? Theme.accent).frame(width: 4).padding(.vertical, Theme.Space.m)
        }
    }
}

/// One transaction: its category on a tile, what and when, the amount; money coming back is blue with a plus.
private struct DayListTransactionLine: View {
    let title: String
    let detail: String
    let amountText: String
    let isRefund: Bool
    let category: CanonicalCategoryID?
    let onTap: () -> Void

    init(title: String, detail: String, amount: Money, isRefund: Bool, category: CanonicalCategoryID?, onTap: @escaping () -> Void) {
        self.init(title: title, detail: detail, amountText: Formatting.money(amount.minorUnits, currency: amount.currency), isRefund: isRefund, category: category, onTap: onTap)
    }

    init(title: String, detail: String, amountText: String, isRefund: Bool, category: CanonicalCategoryID?, onTap: @escaping () -> Void) {
        self.title = title
        self.detail = detail
        self.amountText = amountText
        self.isRefund = isRefund
        self.category = category
        self.onTap = onTap
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Theme.Space.m) {
                IconTile(
                    systemName: CategoryIcon.symbol(for: category) ?? (isRefund ? "arrow.uturn.backward" : "creditcard"),
                    tint: isRefund ? Theme.accent : Theme.textSecondary, size: 36
                )
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text(title).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text(detail).font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: Theme.Space.s)
                Text((isRefund ? "+" : "") + amountText).font(Theme.Typo.amount).foregroundStyle(Theme.amountColor(isIncoming: isRefund))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Opens one transaction's details (with editing) from the calendar: the ledger entry is read when the sheet appears.
struct LedgerEntryLoader: View {
    let id: LedgerEntryID
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var entry: LedgerListEntry?
    @State private var missing = false

    var body: some View {
        NavigationStack {
            Group {
                if let entry {
                    TransactionDetailView(entry: entry, model: model)
                } else if missing {
                    Text("이 거래를 찾지 못했어요").foregroundStyle(Theme.textTertiary)
                } else {
                    ProgressView()
                }
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
        }
        .task(id: model.overrideRevision) {
            let sections = await model.ledgerSections() ?? []
            entry = sections.lazy.flatMap(\.entries).first { $0.id == id }
            missing = entry == nil
        }
    }
}
