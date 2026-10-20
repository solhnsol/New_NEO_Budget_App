import NEOBudgetCalendar
import SwiftUI

/// Read-only details for a tapped all-day item or transaction marker. Event blocks open in place instead.
struct EventDetailView: View {
    let selection: TimelineSelection
    let zoneIdentifier: String
    /// Opens the event's Activity sheet (type, place, people, transactions). Only for an event selection.
    var onEditInfo: (EventBlock) -> Void = { _ in }
    /// Opens the event's settlement (who was there, how many, who owes what). Only for an event selection.
    var onSettle: (EventBlock) -> Void = { _ in }

    var body: some View {
        NavigationStack {
            List {
                switch selection {
                case let .allDay(item): allDaySections(item)
                case let .event(block): eventSections(block)
                case let .marker(marker): markerSections(marker)
                case let .allocation(item, eventTitle): allocationSection(item, eventTitle: eventTitle)
                case let .overflow(selection): overflowSections(selection)
                }
            }
            .onAllGroupedScreen()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var title: String {
        switch selection {
        case let .allDay(item): return item.title
        case let .event(block): return block.title
        case let .marker(marker): return marker.title ?? "지출"
        case let .allocation(item, _): return item.title ?? "거래"
        case let .overflow(selection): return selection.counts
        }
    }

    @ViewBuilder
    private func eventSections(_ block: EventBlock) -> some View {
        Section {
            row("시간", Formatting.timeRange(block.startUnixMilliseconds, block.endUnixMilliseconds, zoneIdentifier: zoneIdentifier) + (block.state == .eventMissing ? " · 캘린더에서 삭제됨" : ""))
            ForEach(ExpandedBlockPlan.metaRows(for: block), id: \.label) { meta in row(meta.label, meta.value) }
            if !block.isEditable { row("편집", "읽기 전용") }
        }
        Section {
            Button { onEditInfo(block) } label: { actionRow("무엇을, 어디서, 누구와", systemImage: "square.and.pencil") }
            Button { onSettle(block) } label: { actionRow("정산하기", systemImage: "person.2") }
        }
        allocationSections(block.allocations, spend: block.allocatedSpend, refunds: block.allocatedRefunds)
    }

    @ViewBuilder
    private func allDaySections(_ item: AllDayItem) -> some View {
        Section {
            row("기간", item.firstDay == item.lastDay
                ? Formatting.dayTitle(item.firstDay)
                : Formatting.dayTitle(item.firstDay) + " – " + Formatting.dayTitle(item.lastDay))
            if let calendar = item.calendarTitle { row("캘린더", calendar) }
            if !item.isEditable { row("편집", "읽기 전용") }
        }
        allocationSections(item.allocations, spend: item.allocatedSpend, refunds: item.allocatedRefunds)
    }

    @ViewBuilder
    private func allocationSection(_ item: AllocationItem, eventTitle: String?) -> some View {
        Section {
            row(item.flow == .refund ? "환불" : "지출", Formatting.money(item.transactionAmount.minorUnits, currency: item.transactionAmount.currency))
            row("시각", Formatting.time(item.occurredAtUnixMilliseconds, zoneIdentifier: zoneIdentifier) + (item.timePrecision == .approximate ? " (알림 기준)" : ""))
            if let eventTitle { row("연결된 일정", eventTitle) }
        } footer: {
            Text("거래 시각이 일정 시간 밖이라 따로 보여요. 일정과의 연결은 그대로예요.")
        }
    }

    /// The transactions an overflow stands for, in time order. Nothing is merged: each is listed as it is.
    @ViewBuilder
    private func overflowSections(_ selection: OverflowSelection) -> some View {
        Section {
            ForEach(selection.rows) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title ?? "거래").font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary)
                        Text(Formatting.clock(minute: item.minute) + " · " + AmountKindNames.name(item.kind)).font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    Text(item.amount).font(Theme.Typo.amount).foregroundStyle(Theme.textPrimary)
                }
            }
        } footer: {
            Text("자리가 모자라 한 카드로 모아 보인 거래예요. 서로 관련 있다는 뜻은 아니에요.")
        }
    }

    @ViewBuilder
    private func markerSections(_ marker: TransactionMarkerItem) -> some View {
        Section {
            row(marker.flow == .refund ? "환불" : "지출", Formatting.money(marker.amount.minorUnits, currency: marker.amount.currency))
            row("시각", Formatting.time(marker.occurredAtUnixMilliseconds, zoneIdentifier: zoneIdentifier) + (marker.timePrecision == .approximate ? " (알림 기준)" : ""))
            row("활동", marker.allocations.isEmpty ? "연결된 활동 없음" : "\(marker.allocations.count)개에 나눔")
        } footer: {
            if marker.allocations.isEmpty { Text("활동 없는 지출도 괜찮아요. 나중에 일정과 연결할 수 있어요.") }
        }
    }

    @ViewBuilder
    private func allocationSections(_ allocations: [AllocationItem], spend: [AmountAggregate], refunds: [AmountAggregate]) -> some View {
        if !allocations.isEmpty {
            Section("연결된 지출") {
                ForEach(spend, id: \.currency) { total in row("합계", Formatting.aggregate(total)) }
                ForEach(refunds, id: \.currency) { total in row("환불", Formatting.aggregate(total)) }
                ForEach(allocations, id: \.allocationID) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title ?? "거래").font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary)
                        Text(Formatting.knowledge(item.allocatedAmount, currency: item.transactionAmount.currency)
                             + (item.isPartOfTransaction ? " (전체 " + Formatting.money(item.transactionAmount.minorUnits, currency: item.transactionAmount.currency) + " 중)" : ""))
                            .font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary)
                    }
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent {
            Text(value).multilineTextAlignment(.trailing).foregroundStyle(Theme.textPrimary)
        } label: {
            Text(label).foregroundStyle(Theme.textSecondary)
        }
    }

    private func actionRow(_ title: String, systemImage: String) -> some View {
        HStack(spacing: Theme.Space.m) {
            IconTile(systemName: systemImage, tint: Theme.accent, size: 32)
            Text(title).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary)
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.textTertiary)
        }
    }
}
