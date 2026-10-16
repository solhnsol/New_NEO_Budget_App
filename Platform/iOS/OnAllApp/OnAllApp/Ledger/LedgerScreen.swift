import NEOBudgetCalendar
import NEOBudgetCore
import SwiftUI

/// The ledger tab: every spend and refund as a plain list, newest day first. No grid; tapping a row opens its details.
struct LedgerScreen: View {
    let model: AppModel
    @State private var sections: [LedgerDaySection]?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("가계부")
                .refreshable { await load() }
        }
        // A calendar-side edit (linking a transaction to an activity) reloads the data, and the list follows it.
        .task(id: model.dataGeneration) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch sections {
        case .none:
            ProgressView("거래를 불러오는 중").frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .some(sections) where sections.isEmpty:
            ContentUnavailableView("거래 내역이 없습니다", systemImage: "wonsign.circle", description: Text("결제 알림이 들어오면 여기에 쌓입니다."))
        case let .some(sections):
            List {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.entries) { entry in
                            NavigationLink {
                                TransactionDetailView(entry: entry, zone: model.dayZone)
                            } label: {
                                LedgerRow(entry: entry, zoneIdentifier: model.dayZone.identifier)
                            }
                        }
                    } header: {
                        HStack {
                            Text(Formatting.dayTitle(section.day))
                            Spacer()
                            Text(section.totals.map { Formatting.money($0.minorUnits, currency: $0.currency) }.joined(separator: " · "))
                                .monospacedDigit()
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func load() async {
        if let loaded = await model.ledgerSections() { sections = loaded } else if sections == nil { sections = [] }
    }
}

/// One transaction line: what, when and which activities; the amount on the right (a refund in green with a plus).
struct LedgerRow: View {
    let entry: LedgerListEntry
    let zoneIdentifier: String

    var body: some View {
        let transaction = entry.transaction
        HStack(spacing: 12) {
            Image(systemName: CategoryIcon.symbol(for: entry.categoryID) ?? (transaction.flow == .refund ? "arrow.uturn.backward" : "creditcard"))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.title ?? "거래").lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text((transaction.flow == .refund ? "+" : "") + Formatting.money(transaction.amount.minorUnits, currency: transaction.amount.currency))
                .monospacedDigit()
                .foregroundStyle(transaction.flow == .refund ? Color.green : Color.primary)
        }
    }

    private var subtitle: String {
        var parts = [Formatting.time(entry.transaction.occurredAtUnixMilliseconds, zoneIdentifier: zoneIdentifier)]
        if entry.transaction.flow == .refund { parts.append("환불") }
        parts.append(contentsOf: entry.activityTitles)
        return parts.joined(separator: " · ")
    }
}
