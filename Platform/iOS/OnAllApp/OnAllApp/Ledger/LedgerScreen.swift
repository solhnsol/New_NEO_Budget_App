import Foundation
import NEOBudgetCalendar
import NEOBudgetCore
import SwiftUI

/// The ledger tab, in two readings of the same ledger:
/// - **소비**: every spend and refund as a plain list, newest day first, as the timeline shows them. No grid; tapping a row opens its details.
/// - **계좌·카드**: what really moved on each account and card, unnetted, to compare with the bank, and each card's usage this month.
struct LedgerScreen: View {
    enum Mode: Hashable { case spending, accounts }

    let model: AppModel
    @State private var mode = Mode.spending
    @State private var sections: [LedgerDaySection]?

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .spending: content.refreshable { await load() }
                case .accounts: AccountsView(model: model)
                }
            }
            .navigationTitle("가계부")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("보기", selection: $mode) {
                        Text("소비").tag(Mode.spending)
                        Text("계좌·카드").tag(Mode.accounts)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)
                }
            }
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
                        LedgerDayHeader(section: section, isToday: section.day == today)
                    }
                }
            }
            // One continuous scroll: plain sections whose day header stays pinned until the next day pushes it away.
            .listStyle(.plain)
        }
    }

    private var today: LocalDate { model.dayZone.localDate(of: Int64(Date().timeIntervalSince1970 * 1_000)) }

    private func load() async {
        if let loaded = await model.ledgerSections() { sections = loaded } else if sections == nil { sections = [] }
    }
}

/// The boundary between two days: the date (and "오늘"), then the day's net spending, on a bar that stays at the top while its day scrolls.
struct LedgerDayHeader: View {
    let section: LedgerDaySection
    let isToday: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(Formatting.dayTitle(section.day)).font(.headline).foregroundStyle(.primary)
            if isToday { Text("오늘").font(.caption.weight(.semibold)).foregroundStyle(.tint) }
            Spacer()
            Text(section.totals.map { Formatting.money($0.minorUnits, currency: $0.currency) }.joined(separator: " · "))
                .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
        }
        .textCase(nil)
        .padding(.top, 6)
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
