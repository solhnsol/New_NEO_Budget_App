import NEOBudgetCalendar
import SwiftUI

/// Read-only details for a tapped block, all-day item or transaction marker. Editing arrives with the gesture work.
struct EventDetailView: View {
    let selection: TimelineSelection
    let zoneIdentifier: String

    var body: some View {
        NavigationStack {
            List {
                switch selection {
                case let .block(block): blockSections(block)
                case let .allDay(item): allDaySections(item)
                case let .marker(marker): markerSections(marker)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var title: String {
        switch selection {
        case let .block(block): return block.title
        case let .allDay(item): return item.title
        case let .marker(marker): return marker.title ?? "지출"
        }
    }

    @ViewBuilder
    private func blockSections(_ block: EventBlock) -> some View {
        Section {
            row("시간", Formatting.timeRange(block.startUnixMilliseconds, block.endUnixMilliseconds, zoneIdentifier: zoneIdentifier))
            if let calendar = block.calendarTitle { row("캘린더", calendar) }
            if block.isRecurringInstance { row("반복", "반복 일정의 한 회차") }
            if !block.isEditable { row("편집", "읽기 전용") }
            if block.state == .eventMissing { Text("캘린더에서 삭제된 일정입니다. 연결된 지출 기록을 위해 마지막 상태로 보여줍니다.").font(.footnote) }
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
    private func markerSections(_ marker: TransactionMarkerItem) -> some View {
        Section {
            row(marker.flow == .refund ? "환불" : "지출", Formatting.money(marker.amount.minorUnits, currency: marker.amount.currency))
            row("시각", Formatting.time(marker.occurredAtUnixMilliseconds, zoneIdentifier: zoneIdentifier) + (marker.timePrecision == .approximate ? " (알림 기준)" : ""))
            row("활동", marker.allocations.isEmpty ? "연결된 활동 없음" : "\(marker.allocations.count)개에 나눔")
        } footer: {
            if marker.allocations.isEmpty { Text("활동 없는 지출도 정상입니다. 나중에 일정과 연결할 수 있습니다.") }
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
                        Text(item.title ?? "거래").font(.body)
                        Text(Formatting.knowledge(item.allocatedAmount, currency: item.transactionAmount.currency)
                             + (item.isPartOfTransaction ? " (전체 " + Formatting.money(item.transactionAmount.minorUnits, currency: item.transactionAmount.currency) + " 중)" : ""))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) { Text(value).multilineTextAlignment(.trailing) }
    }
}
