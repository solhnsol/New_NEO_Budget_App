import Foundation
import NEOBudgetCalendar
import NEOBudgetCore

/// The ledger as the bank and the card company see it: every entry that moved money in an account or on a card, with its real sign, never netted
/// against refunds or settlements. It is what is compared with a bank statement, and what card usage (실적, 한도) is counted from. The spending view
/// (`LedgerList`) is a separate, display-only reading of the same ledger. Pure, so it is tested.
enum LedgerStatements {
    /// Where money is held or owed.
    enum Source: Hashable {
        case account(AccountID)
        case card(CreditInstrumentID)
    }

    /// One movement on one source.
    struct Line: Identifiable, Equatable {
        let entryID: LedgerEntryID
        let kind: LedgerEntry.Kind
        let occurredAtUnixMilliseconds: Int64
        let title: String?
        /// Account: money in (+) or out (−). Card: usage (+, debt grows) or payment and cancellation (−).
        let delta: Money
        /// Account only: the balance right after this line.
        let balanceAfter: Int64?
        /// What the notification said the money moved on, e.g. "체크 1234" (a debit card on this account).
        let instrument: InstrumentHint?
        var id: String { entryID.rawValue }
    }

    struct Statement: Identifiable, Equatable {
        let source: Source
        let name: String
        let currency: String
        /// Newest first.
        let lines: [Line]
        /// Account: its balance now. Card: what is owed now.
        let current: Int64
        var id: Source { source }
    }

    /// Usage on one card in a month, as the card company counts it for 실적 and 한도: what was charged, less cancellations and refunds to the
    /// card. Money a friend sent back for a shared meal is not on the card and does not reduce it.
    struct CardUsage: Identifiable, Equatable {
        enum Card: Hashable {
            case credit(CreditInstrumentID)
            /// A debit card, known only from the notifications (its account, and the masked number or name they gave).
            case debit(account: AccountID, hint: String)
        }

        let card: Card
        let name: String
        let currency: String
        let usedMinorUnits: Int64
        let count: Int
        var id: Card { card }
    }

    // MARK: Statements

    static func statements(_ snapshot: CandidateProcessingSnapshot, configuration: LedgerConfiguration) -> [Statement] {
        let titles = LedgerTimelineProjection.details(from: snapshot).titles
        let instruments = instruments(from: snapshot)
        let entries = snapshot.ledger.entries.sorted { ($0.occurredAtUnixMilliseconds, $0.id.rawValue) < ($1.occurredAtUnixMilliseconds, $1.id.rawValue) }

        let accounts = configuration.accounts.map { account -> Statement in
            var balance = account.openingBalance.minorUnits
            var lines: [Line] = []
            for entry in entries {
                for posting in entry.postings where posting.accountID == account.id {
                    balance += posting.delta.minorUnits
                    lines.append(line(entry, delta: posting.delta, balanceAfter: balance, titles: titles, instruments: instruments))
                }
            }
            return Statement(source: .account(account.id), name: account.name, currency: account.openingBalance.currency, lines: lines.reversed(), current: balance)
        }
        let cards = configuration.creditInstruments.map { card -> Statement in
            var owed: Int64 = 0
            var lines: [Line] = []
            for entry in entries {
                for change in entry.liabilityChanges where change.instrumentID == card.id {
                    owed += change.delta.minorUnits
                    lines.append(line(entry, delta: change.delta, balanceAfter: nil, titles: titles, instruments: instruments))
                }
            }
            return Statement(source: .card(card.id), name: card.name, currency: card.currency, lines: lines.reversed(), current: owed)
        }
        return accounts + cards
    }

    private static func line(_ entry: LedgerEntry, delta: Money, balanceAfter: Int64?, titles: [LedgerEntryID: String], instruments: [LedgerEntryID: InstrumentHint]) -> Line {
        var title = titles[entry.id]
        if title == nil, let link = entry.adjustment { title = titles[link.originalEntryID] }
        return Line(
            entryID: entry.id, kind: entry.kind, occurredAtUnixMilliseconds: entry.occurredAtUnixMilliseconds, title: title,
            delta: delta, balanceAfter: balanceAfter, instrument: instruments[entry.id]
        )
    }

    /// What each entry's notifications said it moved on; a card is preferred over a bare account when several notifications back one entry.
    static func instruments(from snapshot: CandidateProcessingSnapshot) -> [LedgerEntryID: InstrumentHint] {
        var found: [LedgerEntryID: InstrumentHint] = [:]
        for stored in snapshot.candidates.values {
            guard let entryID = stored.promotedEntryID, let hint = stored.candidate.sourceDraft?.instrument else { continue }
            if let known = found[entryID], rank(known.kind) >= rank(hint.kind) { continue }
            found[entryID] = hint
        }
        return found
    }

    private static func rank(_ kind: InstrumentHintKind) -> Int {
        switch kind {
        case .creditCard, .debitCard: return 2
        case .unknown: return 0
        default: return 1
        }
    }

    // MARK: Card usage

    /// Each card's usage in `month` (by the day it happened, in `zone`). Credit cards from their debt; debit cards from the account lines whose
    /// notification named a debit card. Only purchases and their cancellations count, never card bill payments or transfers.
    static func cardUsage(_ statements: [Statement], month: BudgetMonth, zone: DisplayTimeZone) -> [CardUsage] {
        func inMonth(_ line: Line) -> Bool {
            let day = zone.localDate(of: line.occurredAtUnixMilliseconds)
            return day.year == month.year && day.month == month.month
        }
        func counts(_ line: Line) -> Bool { (line.kind == .expense || line.kind == .adjustment) && inMonth(line) }

        var result: [CardUsage] = []
        for statement in statements {
            switch statement.source {
            case let .card(id):
                let lines = statement.lines.filter(counts)
                result.append(CardUsage(
                    card: .credit(id), name: statement.name, currency: statement.currency,
                    usedMinorUnits: lines.reduce(0) { $0 + $1.delta.minorUnits }, count: lines.filter { $0.kind == .expense }.count
                ))
            case let .account(id):
                let debit = statement.lines.filter { counts($0) && $0.instrument?.kind == .debitCard }
                let byCard = Dictionary(grouping: debit) { debitName($0.instrument) }
                for name in byCard.keys.sorted() {
                    let lines = byCard[name] ?? []
                    result.append(CardUsage(
                        card: .debit(account: id, hint: name), name: name + " (" + statement.name + ")", currency: statement.currency,
                        // Account lines are money out (−); usage is what was spent.
                        usedMinorUnits: -lines.reduce(0) { $0 + $1.delta.minorUnits }, count: lines.filter { $0.kind == .expense }.count
                    ))
                }
            }
        }
        return result
    }

    private static func debitName(_ hint: InstrumentHint?) -> String {
        let name = hint?.displayNameRaw?.trimmingCharacters(in: .whitespacesAndNewlines)
        let masked = hint?.maskedHint?.trimmingCharacters(in: .whitespacesAndNewlines)
        return [name, masked].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " ").nonEmpty ?? "체크카드"
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
