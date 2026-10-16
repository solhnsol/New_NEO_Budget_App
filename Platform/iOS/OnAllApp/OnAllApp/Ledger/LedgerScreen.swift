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
            .tint(Theme.accent)
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
                if !model.isDemo {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            IntakeInboxView(model: model)
                        } label: {
                            Label("받은 알림", systemImage: "tray")
                        }
                    }
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
            ProgressView("거래를 불러오고 있어요").frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .some(sections) where sections.isEmpty:
            ContentUnavailableView("아직 거래가 없어요", systemImage: "wonsign.circle", description: Text("결제 알림이 오면 여기에 차곡차곡 쌓여요."))
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
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: Theme.Space.s, leading: Theme.Space.xl, bottom: Theme.Space.s, trailing: Theme.Space.l))
                        }
                    } header: {
                        LedgerDayHeader(section: section, isToday: section.day == today)
                    }
                }
            }
            // One continuous scroll: plain sections whose day header stays pinned until the next day pushes it away.
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.surface)
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
        HStack(alignment: .center, spacing: Theme.Space.s) {
            Text(Formatting.dayTitle(section.day)).font(.system(.subheadline, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            if isToday { StatusBadge(text: "오늘", tone: .accent) }
            Spacer()
            // A day whose refunds outweigh its spending got money back: "+3,000원" in blue, not "-3,000원".
            let isMoneyBack = !section.totals.isEmpty && section.totals.allSatisfy { $0.minorUnits < 0 }
            Text(section.totals.map { ($0.minorUnits < 0 ? "+" : "") + Formatting.money(abs($0.minorUnits), currency: $0.currency) }.joined(separator: " · "))
                .font(.system(.subheadline, weight: .medium)).monospacedDigit().foregroundStyle(isMoneyBack ? Theme.accent : Theme.textTertiary)
        }
        .textCase(nil)
        .padding(.top, Theme.Space.m)
        .padding(.bottom, Theme.Space.xs)
    }
}

/// One transaction line: its category on a tile, what and when (and which activities), the amount on the right; a refund is blue with a plus, as
/// Korean banks show money coming back. A purchase that got money back shows what it cost after that, the charged amount struck through under
/// it, and one small line per refund or settlement.
struct LedgerRow: View {
    let entry: LedgerListEntry
    let zoneIdentifier: String

    var body: some View {
        let transaction = entry.transaction
        let isRefund = transaction.flow == .refund
        HStack(spacing: Theme.Space.m) {
            IconTile(
                systemName: CategoryIcon.symbol(for: entry.categoryID) ?? (isRefund ? "arrow.uturn.backward" : "creditcard"),
                tint: isRefund ? Theme.accent : Theme.textSecondary
            )
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(transaction.title ?? "거래").font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(subtitle).font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                ForEach(entry.offsets) { offset in
                    Text(LedgerRow.offsetLine(offset, currency: transaction.amount.currency, zoneIdentifier: zoneIdentifier))
                        .font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
            }
            Spacer(minLength: Theme.Space.s)
            VStack(alignment: .trailing, spacing: Theme.Space.xxs) {
                Text((isRefund ? "+" : "") + Formatting.money(entry.netMinorUnits ?? transaction.amount.minorUnits, currency: transaction.amount.currency))
                    .font(Theme.Typo.amount)
                    .foregroundStyle(Theme.amountColor(isIncoming: isRefund))
                if entry.netMinorUnits != nil {
                    Text(Formatting.money(transaction.amount.minorUnits, currency: transaction.amount.currency))
                        .font(Theme.Typo.caption).monospacedDigit().strikethrough().foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    /// "환불 19,000 · 10/9" or "민수 정산 30,000 · 10/9".
    static func offsetLine(_ offset: LedgerListEntry.Offset, currency: String, zoneIdentifier: String) -> String {
        let what: String
        switch offset.kind {
        case .refund: what = "환불"
        case let .settlement(from): what = from + " 정산"
        }
        return what + " " + Formatting.money(offset.minorUnits, currency: currency) + " · " + Formatting.shortDate(offset.occurredAtUnixMilliseconds, zoneIdentifier: zoneIdentifier)
    }

    private var subtitle: String {
        var parts = [Formatting.time(entry.transaction.occurredAtUnixMilliseconds, zoneIdentifier: zoneIdentifier)]
        if entry.transaction.flow == .refund { parts.append("환불") }
        parts.append(contentsOf: entry.activityTitles)
        return parts.joined(separator: " · ")
    }
}
