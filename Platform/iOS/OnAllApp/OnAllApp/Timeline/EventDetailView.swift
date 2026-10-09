import NEOBudgetCalendar
import SwiftUI

/// Read-only details for a tapped all-day item or transaction marker. Event blocks open in place instead.
struct EventDetailView: View {
    let selection: TimelineSelection
    let zoneIdentifier: String

    var body: some View {
        NavigationStack {
            List {
                switch selection {
                case let .allDay(item): allDaySections(item)
                case let .marker(marker): markerSections(marker)
                case let .allocation(item, eventTitle): allocationSection(item, eventTitle: eventTitle)
                case let .overflow(selection): overflowSections(selection)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var title: String {
        switch selection {
        case let .allDay(item): return item.title
        case let .marker(marker): return marker.title ?? "지출"
        case let .allocation(item, _): return item.title ?? "거래"
        case let .overflow(selection): return selection.counts
        }
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
            Text("거래가 일어난 시각은 일정 시간 밖이라 일정과 별개의 줄로 보입니다. 일정과의 연결은 그대로입니다.")
        }
    }

    /// The transactions an overflow stands for, in time order. Nothing is merged: each is listed as it is.
    @ViewBuilder
    private func overflowSections(_ selection: OverflowSelection) -> some View {
        Section {
            ForEach(selection.rows) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title ?? "거래")
                        Text(Formatting.clock(minute: item.minute) + " · " + AmountKindNames.name(item.kind)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(item.amount).monospacedDigit()
                }
            }
        } footer: {
            Text("공간이 모자라 한 카드로 보인 거래입니다. 서로 관련된 거래라는 뜻은 아닙니다.")
        }
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
