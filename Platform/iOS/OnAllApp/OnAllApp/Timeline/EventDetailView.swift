import NEOBudgetCalendar
import SwiftUI

/// The sheet a tapped event, all-day item or transaction marker opens (design-v2 FULL-3 / DETAIL-4): the event's name and time, the spending in it, the
/// total of it, then a few rows. Its one button edits the event's info.
struct EventDetailView: View {
    let selection: TimelineSelection
    let zoneIdentifier: String
    /// Opens the event's Activity sheet (type, place, people, transactions). Only for an event selection.
    var onEditInfo: (EventBlock) -> Void = { _ in }
    /// Opens the event's settlement (who was there, how many, who owes what). Only for an event selection.
    var onSettle: (EventBlock) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetScaffold {
            switch selection {
            case let .event(block): event(block)
            case let .allDay(item): allDay(item)
            case let .marker(marker): markerBody(marker)
            case let .allocation(item, eventTitle): allocation(item, eventTitle: eventTitle)
            case let .overflow(selection): overflow(selection)
            }
        } button: {
            if case let .event(block) = selection {
                Button("편집") { onEditInfo(block) }.buttonStyle(.onAllPrimary).disabled(!block.isEditable && block.activity == nil)
            } else {
                Button("확인") { dismiss() }.buttonStyle(.onAllPrimary)
            }
        }
        .onAllSheet()
    }

    // MARK: Event

    @ViewBuilder
    private func event(_ block: EventBlock) -> some View {
        let time = Formatting.timeRange(block.startUnixMilliseconds, block.endUnixMilliseconds, zoneIdentifier: zoneIdentifier)
        let place = ExpandedBlockPlan.metaRows(for: block).first { $0.label == "장소" }?.value
        SheetTitleBlock(
            title: block.title,
            lines: [time + (block.state == .eventMissing ? " · 캘린더에서 삭제됨" : ""), [block.calendarTitle, place].compactMap { $0 }.joined(separator: " · ")].filter { !$0.isEmpty },
            barColor: Color(hex: block.calendarColorHex)
        )
        if !block.allocations.isEmpty {
            SheetSectionLabel("이 일정의 지출")
            ForEach(block.allocations, id: \.allocationID) { item in spendRow(item) }
            ForEach(block.allocatedSpend, id: \.currency) { total in
                SheetRow(label: "내 지출 합계", value: Formatting.spent(total.knownMinorUnits), valueColor: Theme.accent, valueWeight: .semibold)
            }
            ForEach(block.allocatedRefunds, id: \.currency) { total in
                SheetRow(label: "환불", value: "+" + Formatting.grouped(total.knownMinorUnits), valueColor: Theme.income, valueWeight: .semibold)
            }
        }
        Button { onEditInfo(block) } label: {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "plus").font(.system(size: 14, weight: .medium))
                Text("지출 연결하기").font(Theme.Typo.rowTitle)
                Spacer()
            }
            .foregroundStyle(Theme.textTertiary).frame(minHeight: Theme.rowHeight).contentShape(Rectangle())
        }
        .buttonStyle(.onAllRow)
        .overlay(alignment: .bottom) { Theme.divider.frame(height: 1) }
        SheetRow(label: "정산", value: "정산하기", showsChevron: true) { onSettle(block) }
        ForEach(ExpandedBlockPlan.metaRows(for: block).filter { ["유형", "참여자", "태그"].contains($0.label) }, id: \.label) { meta in
            SheetRow(label: meta.label, value: meta.value)
        }
        if !block.isEditable { SheetRow(label: "편집", value: "읽기 전용") }
    }

    private func spendRow(_ item: AllocationItem) -> some View {
        HStack(spacing: Theme.Space.m) {
            CategoryTile(category: item.categoryID)
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(item.title ?? "거래").font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                if item.isPartOfTransaction {
                    Text("전체 " + Formatting.money(item.transactionAmount.minorUnits, currency: item.transactionAmount.currency) + " 중")
                        .font(Theme.Typo.label).foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer(minLength: Theme.Space.s)
            Text(amount(item.allocatedAmount, flow: item.flow, currency: item.transactionAmount.currency))
                .font(Theme.Typo.amount).foregroundStyle(Theme.amountColor(isIncoming: item.flow == .refund))
        }
        .frame(minHeight: 64)
    }

    /// `−9,500`; a refund `+9,500`; an amount not known exactly keeps its words (`약 …`).
    private func amount(_ knowledge: AmountKnowledge, flow: TransactionFlow, currency: String) -> String {
        if case let .exact(value) = knowledge, currency == "KRW" { return flow == .refund ? "+" + Formatting.grouped(value) : Formatting.spent(value) }
        return Formatting.knowledge(knowledge, currency: currency)
    }

    // MARK: Other selections

    @ViewBuilder
    private func allDay(_ item: AllDayItem) -> some View {
        let period = item.firstDay == item.lastDay
            ? Formatting.dayTitle(item.firstDay)
            : Formatting.dayTitle(item.firstDay) + " – " + Formatting.dayTitle(item.lastDay)
        SheetTitleBlock(title: item.title, lines: [period, item.calendarTitle ?? ""].filter { !$0.isEmpty }, barColor: Color(hex: item.calendarColorHex))
        if !item.allocations.isEmpty {
            SheetSectionLabel("이 일정의 지출")
            ForEach(item.allocations, id: \.allocationID) { spendRow($0) }
            ForEach(item.allocatedSpend, id: \.currency) { total in
                SheetRow(label: "내 지출 합계", value: Formatting.spent(total.knownMinorUnits), valueColor: Theme.accent, valueWeight: .semibold)
            }
        }
        if !item.isEditable { SheetRow(label: "편집", value: "읽기 전용") }
    }

    @ViewBuilder
    private func markerBody(_ marker: TransactionMarkerItem) -> some View {
        let isRefund = marker.flow == .refund
        SheetTitleBlock(title: marker.title ?? "지출", lines: [])
        Text((isRefund ? "+" : "−") + Formatting.money(marker.amount.minorUnits, currency: marker.amount.currency))
            .font(Theme.Typo.hero).foregroundStyle(Theme.amountColor(isIncoming: isRefund)).padding(.vertical, Theme.Space.xl)
        SheetRow(label: "시각", value: Formatting.time(marker.occurredAtUnixMilliseconds, zoneIdentifier: zoneIdentifier) + (marker.timePrecision == .approximate ? " (알림 기준)" : ""))
        SheetRow(label: "일정", value: marker.allocations.isEmpty ? nil : "\(marker.allocations.count)개에 나눔")
    }

    @ViewBuilder
    private func allocation(_ item: AllocationItem, eventTitle: String?) -> some View {
        let isRefund = item.flow == .refund
        SheetTitleBlock(title: item.title ?? "거래", lines: [])
        Text((isRefund ? "+" : "−") + Formatting.money(item.transactionAmount.minorUnits, currency: item.transactionAmount.currency))
            .font(Theme.Typo.hero).foregroundStyle(Theme.amountColor(isIncoming: isRefund)).padding(.vertical, Theme.Space.xl)
        SheetRow(label: "시각", value: Formatting.time(item.occurredAtUnixMilliseconds, zoneIdentifier: zoneIdentifier) + (item.timePrecision == .approximate ? " (알림 기준)" : ""))
        if let eventTitle { SheetRow(label: "연결된 일정", value: eventTitle) }
    }

    /// The transactions an overflow stands for, in time order. Nothing is merged: each is listed as it is.
    @ViewBuilder
    private func overflow(_ selection: OverflowSelection) -> some View {
        SheetTitleBlock(title: selection.counts, lines: [])
        ForEach(selection.rows) { item in
            HStack(spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text(item.title ?? "거래").font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary)
                    Text(Formatting.clock(minute: item.minute)).font(Theme.Typo.label).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                Text(item.amount).font(Theme.Typo.amount).foregroundStyle(Theme.textPrimary)
            }
            .frame(minHeight: 64)
        }
    }
}
