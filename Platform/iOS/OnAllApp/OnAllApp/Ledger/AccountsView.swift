import Foundation
import NEOBudgetCalendar
import NEOBudgetCore
import SwiftUI

/// The ledger tab's 계좌·카드 reading: each card's usage this month (what the card company counts, whatever was settled back), then every account and
/// card with its balance or debt, each opening its own statement.
struct AccountsView: View {
    let model: AppModel
    @State private var statements: [LedgerStatements.Statement]?

    var body: some View {
        content
            .refreshable { await load() }
            .task(id: model.dataGeneration) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch statements {
        case .none:
            ProgressView("계좌를 불러오고 있어요").frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .some(statements) where statements.isEmpty:
            ContentUnavailableView("등록한 계좌가 없어요", systemImage: "building.columns", description: Text("계좌와 카드를 등록하면 실제 내역을 여기서 볼 수 있어요."))
        case let .some(statements):
            List {
                let usage = month.map { LedgerStatements.cardUsage(statements, month: $0, zone: model.dayZone) } ?? []
                if !usage.isEmpty {
                    Section {
                        ForEach(usage) { card in
                            MoneyRow(symbol: "creditcard", title: card.name, subtitle: "\(card.count)건", amount: Formatting.money(card.usedMinorUnits, currency: card.currency))
                        }
                    } header: {
                        Text(month.map { "\($0.month)월 카드 사용" } ?? "카드 사용")
                    } footer: {
                        Text("카드사 기준(실적·한도) 금액이에요. 결제 취소는 빠지고, 정산으로 돌려받은 돈은 빠지지 않아요.")
                    }
                    .onAllCardRow()
                }
                let accounts = statements.filter { if case .account = $0.source { true } else { false } }
                let cards = statements.filter { if case .card = $0.source { true } else { false } }
                if !accounts.isEmpty { sourceSection("계좌", accounts, label: "잔액") }
                if !cards.isEmpty { sourceSection("신용카드", cards, label: "결제할 금액") }
            }
            .onAllGroupedScreen()
        }
    }

    private func sourceSection(_ title: String, _ statements: [LedgerStatements.Statement], label: String) -> some View {
        Section(title) {
            ForEach(statements) { statement in
                NavigationLink {
                    StatementView(statement: statement, zone: model.dayZone)
                } label: {
                    MoneyRow(
                        symbol: Self.symbol(statement.source),
                        title: statement.name, subtitle: label, amount: Formatting.money(statement.current, currency: statement.currency)
                    )
                }
            }
        }
        .onAllCardRow()
    }

    private static func symbol(_ source: LedgerStatements.Source) -> String {
        switch source {
        case .account: return "building.columns"
        case .card: return "creditcard"
        }
    }

    private var month: BudgetMonth? {
        let today = model.dayZone.localDate(of: Int64(Date().timeIntervalSince1970 * 1_000))
        return try? BudgetMonth(year: today.year, month: today.month)
    }

    private func load() async {
        if let loaded = await model.ledgerStatements() { statements = loaded } else if statements == nil { statements = [] }
    }
}

/// One account's or card's movements as its statement would list them: one continuous scroll, newest first, a pinned header per day, each line with
/// its real sign and, for an account, the balance after it.
struct StatementView: View {
    let statement: LedgerStatements.Statement
    let zone: DisplayTimeZone

    var body: some View {
        let days = Dictionary(grouping: statement.lines) { zone.localDate(of: $0.occurredAtUnixMilliseconds) }
        List {
            if statement.anchorAdjustment != 0 {
                Text("알림에 찍힌 마지막 잔액에 맞춰 보여 드려요. 아직 확인하지 못한 입출금이 있으면 아래 내역을 더한 값과 다를 수 있어요.")
                    .font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary)
                    .listRowSeparator(.hidden)
            }
            ForEach(days.keys.sorted(by: >), id: \.self) { day in
                Section {
                    ForEach(days[day] ?? []) { line in
                        StatementRow(line: line, currency: statement.currency, isCard: isCard, zone: zone)
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    Text(Formatting.dayTitle(day)).font(.system(.subheadline, weight: .semibold)).foregroundStyle(Theme.textSecondary).textCase(nil)
                        .padding(.top, Theme.Space.s)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.surface)
        .overlay {
            if statement.lines.isEmpty { ContentUnavailableView("아직 내역이 없어요", systemImage: "list.bullet") }
        }
        .navigationTitle(statement.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var isCard: Bool { if case .card = statement.source { true } else { false } }
}

private struct StatementRow: View {
    let line: LedgerStatements.Line
    let currency: String
    let isCard: Bool
    let zone: DisplayTimeZone

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(line.title ?? kindName).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(subtitle).font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            Spacer(minLength: Theme.Space.s)
            VStack(alignment: .trailing, spacing: Theme.Space.xxs) {
                Text(signedAmount).font(Theme.Typo.amount).foregroundStyle(Theme.amountColor(isIncoming: isIncrease))
                if let balance = line.balanceAfter {
                    Text(Formatting.money(balance, currency: currency)).font(Theme.Typo.caption).monospacedDigit().foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    /// Money into an account, or debt on a card going down, is the "good" direction.
    private var isIncrease: Bool { isCard ? line.delta.minorUnits < 0 : line.delta.minorUnits > 0 }

    private var signedAmount: String {
        let value = line.delta.minorUnits
        return (value > 0 ? "+" : value < 0 ? "−" : "") + Formatting.money(abs(value), currency: currency)
    }

    private var subtitle: String {
        var parts = [Formatting.time(line.occurredAtUnixMilliseconds, zoneIdentifier: zone.identifier), kindName]
        if let instrument = line.instrument, instrument.kind == .debitCard {
            let name = [instrument.displayNameRaw, instrument.maskedHint].compactMap { $0 }.joined(separator: " ")
            parts.append(name.isEmpty ? "체크카드" : name)
        }
        return parts.joined(separator: " · ")
    }

    private var kindName: String {
        switch line.kind {
        case .expense: return "결제"
        case .income: return "입금"
        case .transfer: return "이체"
        case .cardPayment: return "카드대금"
        case .adjustment: return "취소·환불"
        case .reversal: return "되돌림"
        }
    }
}

/// An account, a card or a card's usage: its icon on a tile, its name and what the number is, and the number on the right.
private struct MoneyRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    let amount: String

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            IconTile(systemName: symbol)
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(title).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(subtitle).font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: Theme.Space.s)
            Text(amount).font(Theme.Typo.amount).foregroundStyle(Theme.textPrimary)
        }
        .padding(.vertical, Theme.Space.xxs)
    }
}
