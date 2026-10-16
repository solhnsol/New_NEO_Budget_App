import NEOBudgetCalendar
import NEOBudgetCore
import SwiftUI

/// Read-only details of one transaction from the ledger tab: amount, when, category, and the activities it was split into.
struct TransactionDetailView: View {
    let entry: LedgerListEntry
    let zone: DisplayTimeZone
    private var zoneIdentifier: String { zone.identifier }

    var body: some View {
        let transaction = entry.transaction
        List {
            Section {
                row(transaction.flow == .refund ? "환불" : "지출", Formatting.money(transaction.amount.minorUnits, currency: transaction.amount.currency))
                row("날짜", Formatting.dayTitle(zone.localDate(of: transaction.occurredAtUnixMilliseconds)))
                row("시각", Formatting.time(transaction.occurredAtUnixMilliseconds, zoneIdentifier: zoneIdentifier)
                    + (transaction.timePrecision == .approximate ? " (알림 기준)" : ""))
                if let category = entry.categoryID {
                    LabeledContent("분류") {
                        Label(category.rawValue, systemImage: CategoryIcon.symbol(for: category) ?? "tag")
                    }
                }
            }
            Section {
                if entry.portions.isEmpty {
                    Text("연결된 활동 없음").foregroundStyle(.secondary)
                } else {
                    ForEach(entry.portions, id: \.id) { portion in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(portion.activityTitle ?? "활동 없음")
                            Text(Formatting.knowledge(portion.amount, currency: transaction.amount.currency)
                                 + (portion.eventMissing ? " · 캘린더에서 삭제됨" : ""))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("활동")
            } footer: {
                if entry.portions.isEmpty { Text("활동 없는 지출도 정상입니다. 캘린더 탭에서 일정과 연결할 수 있습니다.") }
            }
        }
        .navigationTitle(transaction.title ?? "거래")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) { Text(value).multilineTextAlignment(.trailing) }
    }
}
