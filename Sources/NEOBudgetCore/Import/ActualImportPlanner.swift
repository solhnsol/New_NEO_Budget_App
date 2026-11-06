import Foundation

/// Why an imported row is still waiting for the user, as if its notification had just arrived and nobody had handled it
/// (`docs/actual-budget-import.md`, the unprocessed rows). The row is in the ledger when it moved money the way a real
/// notification would have (`PendingImport.inLedger`); otherwise it waits in review exactly like a real unexplained one.
public enum PendingReason: String, Codable, Hashable, Sendable {
    /// Actual had no category for it.
    case uncategorized
    /// A purchase with no store or payee name.
    case noName
    /// Money in that nothing explains yet: it shows up under "정리할 입금".
    case unclassifiedDeposit
    /// Money out with no name and no category, which no other record explains.
    case unexplainedWithdrawal
    /// One leg of a transfer, or a transfer the ledger cannot hold (out of a card).
    case unpairedTransfer
    /// Money back on a card with no purchase it is known to return.
    case refundWithoutPurchase
    /// A settlement deposit whose original purchase is not in the file.
    case settlementOriginMissing
    /// A row that should have been recorded but the ledger refused it.
    case notRecorded
}

public struct PendingImport: Equatable, Identifiable, Sendable {
    public let candidateID: TransactionCandidateID
    public let accountName: String
    /// The store or payee as a notification would have named it; nil when it had none.
    public let title: String?
    /// Absolute amount.
    public let amount: Money
    /// Positive when Actual had the money come in to `accountName`, negative when it went out.
    public let signedMinorUnits: Int64
    public let occurredAtUnixMilliseconds: Int64
    public let reasons: [PendingReason]
    /// The money is already counted in the ledger's balances. False for a row that waits in review.
    public let inLedger: Bool

    public var id: String { candidateID.rawValue + "|" + accountName }

    public init(
        candidateID: TransactionCandidateID, accountName: String, title: String?, amount: Money, signedMinorUnits: Int64,
        occurredAtUnixMilliseconds: Int64, reasons: [PendingReason], inLedger: Bool
    ) {
        self.candidateID = candidateID
        self.accountName = accountName
        self.title = title
        self.amount = amount
        self.signedMinorUnits = signedMinorUnits
        self.occurredAtUnixMilliseconds = occurredAtUnixMilliseconds
        self.reasons = reasons
        self.inLedger = inLedger
    }

    public func settingInLedger(_ inLedger: Bool) -> PendingImport {
        PendingImport(
            candidateID: candidateID, accountName: accountName, title: title, amount: amount, signedMinorUnits: signedMinorUnits,
            occurredAtUnixMilliseconds: occurredAtUnixMilliseconds, reasons: reasons, inLedger: inLedger
        )
    }
}

public struct PlannedAccount: Equatable, Sendable {
    public let name: String
    public let kind: ImportedAccountKind
    public let binding: ResolvedLedgerBinding
    /// Starting Balances plus Actual's balance adjustments (`balanceCorrection`). Zero for a card, whose opening debt the
    /// ledger cannot hold.
    public let openingBalance: Int64
    /// The part of the opening balance that came from Actual's "잔액 조정" rows instead of "Starting Balances".
    public let balanceCorrection: Int64
    /// An account the file's rows move money to or from but that the file does not list (a closed account: Actual's tools
    /// leave it out, rows and all). It is made so those transfers keep their shape, with the opening balance that ends it at
    /// zero, which is what a closed account is.
    public let isPlaceholder: Bool
}

/// A deposit that paid back purchases: one income entry, and for each purchase how much of it came back.
public struct PlannedSettlement: Equatable, Sendable {
    public struct Link: Equatable, Sendable {
        public let rowID: String
        public let originEntryID: LedgerEntryID
        public let amount: Money
    }

    public let depositEntryID: LedgerEntryID
    public let occurredAtUnixMilliseconds: Int64
    public let links: [Link]
    public var total: Int64 { links.reduce(0) { $0 + $1.amount.minorUnits } }
}

public struct ImportWarning: Equatable, Sendable {
    public enum Code: String, Sendable {
        case unknownAccount
        case zeroAmount
        case openingBalanceOnCard
        case afterThroughDate
        case invalidDate
        case duplicateRowID
        /// A transfer names an account that is not in the file; a placeholder account stands in for it.
        case counterpartNotExported
    }

    public let code: Code
    public let rowID: String?
    public let detail: String
}

/// How one account's ledger balance compares with the balance Actual had.
public struct AccountReconciliation: Equatable, Sendable {
    public let accountName: String
    public let ledgerBalance: Int64
    public let actualBalance: Int64
    /// Rows that Actual counts and the ledger does not (they wait in review), signed like the balance.
    public let waitingMinorUnits: Int64
    /// Zero when the import accounts for every won.
    public var unexplainedMinorUnits: Int64 { ledgerBalance - actualBalance + waitingMinorUnits }
    public var matches: Bool { unexplainedMinorUnits == 0 }
}

/// What an Actual ledger becomes in OnAll: accounts with their starting balances, then one candidate per act, in date
/// order. Pure and deterministic: the same file gives the same plan, with the same IDs, so importing again never counts
/// anything twice. See `docs/actual-budget-import.md` for the policy (Q1-Q6) this implements.
public struct ImportPlan: Equatable, Sendable {
    public static let currency = "KRW"
    public static let policyVersion = "actual-import-v1"
    public static let unnamedPersonName = "이름 없는 사람"

    public let cutoverUnixMilliseconds: Int64
    public let accounts: [PlannedAccount]
    public let candidates: [TransactionCandidate]
    public let pending: [PendingImport]
    public let settlements: [PlannedSettlement]
    public let warnings: [ImportWarning]
    let balances: [(name: String, kind: ImportedAccountKind, binding: ResolvedLedgerBinding, actual: Int64?)]

    public static func == (lhs: ImportPlan, rhs: ImportPlan) -> Bool {
        lhs.cutoverUnixMilliseconds == rhs.cutoverUnixMilliseconds && lhs.accounts == rhs.accounts && lhs.candidates == rhs.candidates
            && lhs.pending == rhs.pending && lhs.settlements == rhs.settlements && lhs.warnings == rhs.warnings
    }

    /// Compares the ledger a replay produced with the balances Actual showed. A card's balance is the debt, negated.
    public func reconcile(with ledger: LedgerSnapshot, pending: [PendingImport]? = nil) -> [AccountReconciliation] {
        let pending = pending ?? self.pending
        return balances.compactMap { account -> AccountReconciliation? in
            guard let actual = account.actual else { return nil }
            let ledgerBalance: Int64
            switch account.binding {
            case let .account(id): ledgerBalance = ledger.accountBalances[id]?.minorUnits ?? 0
            case let .creditInstrument(id): ledgerBalance = -(ledger.outstandingLiabilities[id]?.minorUnits ?? 0)
            }
            let waiting = pending.filter { $0.accountName == account.name && !$0.inLedger }.reduce(Int64(0)) { $0 + $1.signedMinorUnits }
            return AccountReconciliation(accountName: account.name, ledgerBalance: ledgerBalance, actualBalance: actual, waitingMinorUnits: waiting)
        }
    }
}

public enum ActualImportPlanner {
    public static func plan(_ history: ImportedHistory) throws -> ImportPlan {
        var builder = try Builder(history)
        return try builder.build()
    }

    public static func accountID(named name: String) -> AccountID { AccountID(rawValue: "actual-account:" + name) }
    public static func instrumentID(named name: String) -> CreditInstrumentID { CreditInstrumentID(rawValue: "actual-card:" + name) }
    public static func entryID(forRow id: String) -> LedgerEntryID { LedgerEntryID(rawValue: "actual:" + id) }
    public static func evidenceID(forRow id: String) -> String { "actual:" + id }

    // MARK: Builder

    private struct Row {
        let transaction: ImportedTransaction
        let account: ImportedAccount
        let day: Int64
        /// A name a notification would have carried: the payee, else the name the notification had.
        var name: String? {
            [transaction.payee, transaction.importedPayee]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
        }
        var hasCategory: Bool { !(transaction.category?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
        var id: String { transaction.id }
    }

    private struct Builder {
        let history: ImportedHistory
        let cutover: Int64
        let accountsByName: [String: ImportedAccount]
        var warnings: [ImportWarning] = []
        var candidates: [TransactionCandidate] = []
        var pending: [PendingImport] = []
        var settlements: [PlannedSettlement] = []
        /// Entries that a settlement can name as the purchase it paid back.
        var expenseEntries: [String: LedgerEntryID] = [:]
        var slots: [String: Int] = [:]
        /// Closed accounts the transfers name, with what their transfers add up to (their opening balance).
        var placeholders: [String: Int64] = [:]

        init(_ history: ImportedHistory) throws {
            self.history = history
            cutover = try history.cutoverUnixMilliseconds()
            accountsByName = Dictionary(history.accounts.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        }

        mutating func build() throws -> ImportPlan {
            var rows: [Row] = []
            var seenIDs = Set<String>()
            var openings: [String: Int64] = [:]
            var corrections: [String: Int64] = [:]
            for transaction in history.transactions.sorted(by: { ($0.date, $0.id) < ($1.date, $1.id) }) {
                guard seenIDs.insert(transaction.id).inserted else {
                    warn(.duplicateRowID, transaction.id, "같은 id의 행이 또 있어 뒤의 것은 건너뛰었어요")
                    continue
                }
                guard let account = accountsByName[transaction.account] else {
                    warn(.unknownAccount, transaction.id, "계좌 목록에 없는 계좌: \(transaction.account)")
                    continue
                }
                let day: Int64
                do { day = try history.noonUnixMilliseconds(of: transaction.date) } catch {
                    warn(.invalidDate, transaction.id, "날짜를 읽지 못함: \(transaction.date)")
                    continue
                }
                if day >= cutover { warn(.afterThroughDate, transaction.id, "\(history.through) 이후의 행이에요") }
                let category = transaction.category ?? ""
                if category.contains("Starting Balances") || category.contains("잔액 조정") {
                    guard account.kind != .card else {
                        warn(.openingBalanceOnCard, transaction.id, "카드의 시작 잔액·잔액 조정은 담을 수 없어서 건너뛰었어요: \(account.name)")
                        continue
                    }
                    openings[account.name, default: 0] += transaction.amount
                    if category.contains("잔액 조정") { corrections[account.name, default: 0] += transaction.amount }
                    continue
                }
                guard transaction.amount != 0 else {
                    warn(.zeroAmount, transaction.id, "금액이 0원이라 건너뛰었어요")
                    continue
                }
                rows.append(Row(transaction: transaction, account: account, day: day))
            }

            // Accounts that transfers name and the file does not list: closed accounts.
            for row in rows {
                guard let counterpart = Self.counterpart(of: row.transaction.transfer), accountsByName[counterpart] == nil else { continue }
                placeholders[counterpart, default: 0] += row.transaction.amount
            }
            for name in placeholders.keys.sorted() {
                warn(.counterpartNotExported, nil, "이체 상대 계좌가 파일에 없어 빈 계좌로 대신했어요: \(name)")
            }
            var plannedAccounts = history.accounts.map { account -> PlannedAccount in
                PlannedAccount(
                    name: account.name, kind: account.kind, binding: Self.binding(account),
                    openingBalance: account.kind == .card ? 0 : openings[account.name, default: 0],
                    balanceCorrection: account.kind == .card ? 0 : corrections[account.name, default: 0], isPlaceholder: false
                )
            }
            for name in placeholders.keys.sorted() {
                plannedAccounts.append(PlannedAccount(
                    name: name, kind: .bank, binding: Self.binding(Self.placeholder(name)), openingBalance: placeholders[name] ?? 0,
                    balanceCorrection: 0, isPlaceholder: true
                ))
            }

            var used = Set<String>()
            var transferRows: [Row] = []
            var regular: [Row] = []
            for row in rows { if row.transaction.transfer != nil { transferRows.append(row) } else { regular.append(row) } }

            // Settlement deposits are grouped by the deposit they were split from; every other row stands alone.
            var depositGroups: [String: [Row]] = [:]
            var depositOrder: [String] = []
            var plain: [Row] = []
            for row in regular {
                if row.transaction.amount > 0, row.account.kind != .card, let key = Self.depositKey(of: row) {
                    if depositGroups[key] == nil { depositOrder.append(key) }
                    depositGroups[key, default: []].append(row)
                } else {
                    plain.append(row)
                }
            }

            // Purchases first: a settlement needs to know which purchases exist.
            for row in plain where row.transaction.amount < 0 { try addPurchaseOrWithdrawal(row) }
            for row in plain where row.transaction.amount > 0 { try addDepositOrRefund(row) }
            try addTransfers(transferRows, used: &used)
            for key in depositOrder { try addSettlementDeposit(key, depositGroups[key] ?? []) }

            candidates.sort { lhs, rhs in
                let (l, r) = (lhs.sourceDraft?.occurredAt.unixMilliseconds ?? 0, rhs.sourceDraft?.occurredAt.unixMilliseconds ?? 0)
                return l != r ? l < r : lhs.id.rawValue < rhs.id.rawValue
            }
            pending.sort { ($0.occurredAtUnixMilliseconds, $0.candidateID.rawValue) > ($1.occurredAtUnixMilliseconds, $1.candidateID.rawValue) }
            return ImportPlan(
                cutoverUnixMilliseconds: cutover, accounts: plannedAccounts, candidates: candidates, pending: pending,
                settlements: settlements, warnings: warnings,
                balances: history.accounts.map { ($0.name, $0.kind, Self.binding($0), $0.balance) }
            )
        }

        // MARK: Rows that stand alone

        private mutating func addPurchaseOrWithdrawal(_ row: Row) throws {
            let amount = try Self.money(-row.transaction.amount)
            let name = row.name
            let id = Self.candidateID(row.id)
            if !row.hasCategory && name == nil {
                // Nothing says what this money was: a withdrawal no notification explains.
                let draft = try self.draft(row, kind: .withdrawal, direction: .outflow, amount: amount, includeMemo: true)
                try review(id, [row.id], draft, [.unsupportedEvent])
                note(id, row, title: Self.title(draft), signed: row.transaction.amount, reasons: [.unexplainedWithdrawal, .uncategorized], inLedger: false)
                return
            }
            let binding = Self.binding(row.account)
            let postings: [Posting]
            let liabilities: [LiabilityChange]
            switch binding {
            case let .account(accountID): postings = [Posting(accountID: accountID, delta: try amount.negated())]; liabilities = []
            case let .creditInstrument(instrumentID): postings = []; liabilities = [LiabilityChange(instrumentID: instrumentID, delta: amount)]
            }
            let draft = try self.draft(row, kind: .purchase, direction: .outflow, amount: amount, includeMemo: true)
            let entry = LedgerEntry(
                id: ActualImportPlanner.entryID(forRow: row.id), kind: .expense, occurredAtUnixMilliseconds: draft.occurredAt.unixMilliseconds,
                postings: postings, liabilityChanges: liabilities,
                budgetImpact: BudgetImpact(kind: .expense, amount: amount, attributedMonth: try Self.month(row.transaction.date)),
                evidenceIDs: [ActualImportPlanner.evidenceID(forRow: row.id)]
            )
            try ready(id, [row.id], draft, entry)
            expenseEntries[row.id] = entry.id
            var reasons: [PendingReason] = []
            if !row.hasCategory { reasons.append(.uncategorized) }
            if name == nil { reasons.append(.noName) }
            if !reasons.isEmpty { note(id, row, title: name, signed: row.transaction.amount, reasons: reasons, inLedger: true) }
        }

        private mutating func addDepositOrRefund(_ row: Row) throws {
            let amount = try Self.money(row.transaction.amount)
            let id = Self.candidateID(row.id)
            if row.account.kind == .card {
                // Money back on a card. Which purchase it returns is not known from a bare row, and matching on amount alone is never done.
                let draft = try self.draft(row, kind: .refund, direction: .inflow, amount: amount, includeMemo: true)
                try review(id, [row.id], draft, [.missingOriginalEntry])
                note(id, row, title: row.name ?? Self.title(draft), signed: row.transaction.amount, reasons: [.refundWithoutPurchase], inLedger: false)
                return
            }
            guard case let .account(accountID) = Self.binding(row.account) else { return }
            let draft = try self.draft(row, kind: .deposit, direction: .inflow, amount: amount, includeMemo: true)
            let entry = LedgerEntry(
                id: ActualImportPlanner.entryID(forRow: row.id), kind: .income, occurredAtUnixMilliseconds: draft.occurredAt.unixMilliseconds,
                postings: [Posting(accountID: accountID, delta: amount)], evidenceIDs: [ActualImportPlanner.evidenceID(forRow: row.id)]
            )
            try ready(id, [row.id], draft, entry)
            if !row.hasCategory {
                note(id, row, title: row.name ?? Self.title(draft), signed: row.transaction.amount, reasons: [.unclassifiedDeposit, .uncategorized], inLedger: true)
            }
        }

        // MARK: Transfers

        private mutating func addTransfers(_ rows: [Row], used: inout Set<String>) throws {
            struct Leg { let row: Row; let counterpart: String; let outgoing: Bool }
            func leg(_ row: Row) -> Leg? {
                guard let text = row.transaction.transfer?.trimmingCharacters(in: .whitespaces), let arrow = text.first, arrow == "→" || arrow == "←" else { return nil }
                return Leg(row: row, counterpart: String(text.dropFirst()).trimmingCharacters(in: .whitespaces), outgoing: arrow == "→")
            }
            let allLegs = rows.compactMap(leg)
            for leg in allLegs where placeholders[leg.counterpart] != nil {
                used.insert(leg.row.id)
                try placeholderTransfer(leg.row, counterpart: leg.counterpart, outgoing: leg.outgoing)
            }
            let legs = allLegs.filter { placeholders[$0.counterpart] == nil }
            for row in rows where leg(row) == nil {
                // A transfer mark in a shape we do not know: wait for the user, with the money not counted.
                try unpairedTransfer(row)
            }
            var incoming: [String: [Leg]] = [:]
            for leg in legs where !leg.outgoing {
                incoming["\(leg.row.transaction.date)|\(leg.row.transaction.account)|\(leg.counterpart)|\(leg.row.transaction.amount)", default: []].append(leg)
            }
            for out in legs where out.outgoing {
                let key = "\(out.row.transaction.date)|\(out.counterpart)|\(out.row.transaction.account)|\(-out.row.transaction.amount)"
                guard let inbound = incoming[key]?.first(where: { !used.contains($0.row.id) }), out.row.transaction.amount < 0 else { continue }
                used.insert(inbound.row.id)
                used.insert(out.row.id)
                try pair(out: out.row, in: inbound.row)
            }
            for leg in legs where !used.contains(leg.row.id) { try unpairedTransfer(leg.row) }
        }

        private mutating func pair(out: Row, in inbound: Row) throws {
            let amount = try Self.money(-out.transaction.amount)
            let id = Self.candidateID(out.id)
            let evidence = [out.id, inbound.id]
            let (source, destination) = (out.account, inbound.account)
            func waitsOnBudget() -> Bool { source.onBudget != destination.onBudget }
            guard source.kind != .card else {
                let draft = try self.draft(out, kind: .transferOut, direction: .outflow, amount: amount, includeMemo: true)
                try review(id, evidence, draft, [.unsupportedEvent])
                note(id, out, title: nil, signed: out.transaction.amount, reasons: [.unpairedTransfer], inLedger: false)
                note(id, inbound, title: nil, signed: inbound.transaction.amount, reasons: [.unpairedTransfer], inLedger: false)
                return
            }
            guard case let .account(from) = Self.binding(source) else { return }
            let entry: LedgerEntry
            let draft: TransactionCandidateDraft
            switch Self.binding(destination) {
            case let .account(to):
                draft = try self.draft(out, kind: .transferOut, direction: .outflow, amount: amount, includeMemo: true)
                entry = LedgerEntry(
                    id: ActualImportPlanner.entryID(forRow: out.id), kind: .transfer, occurredAtUnixMilliseconds: draft.occurredAt.unixMilliseconds,
                    postings: [Posting(accountID: from, delta: try amount.negated()), Posting(accountID: to, delta: amount)],
                    evidenceIDs: evidence.map(ActualImportPlanner.evidenceID(forRow:))
                )
            case let .creditInstrument(card):
                draft = try self.draft(out, kind: .cardBillPayment, direction: .outflow, amount: amount, includeMemo: true)
                entry = LedgerEntry(
                    id: ActualImportPlanner.entryID(forRow: out.id), kind: .cardPayment, occurredAtUnixMilliseconds: draft.occurredAt.unixMilliseconds,
                    postings: [Posting(accountID: from, delta: try amount.negated())],
                    liabilityChanges: [LiabilityChange(instrumentID: card, delta: try amount.negated())],
                    evidenceIDs: evidence.map(ActualImportPlanner.evidenceID(forRow:))
                )
            }
            try ready(id, evidence, draft, entry)
            // Actual asks for a category when the money crosses the budget line; the ledger holds the transfer as it is.
            if waitsOnBudget() {
                note(id, out, title: nil, signed: out.transaction.amount, reasons: [.uncategorized], inLedger: true)
            }
        }

        /// A transfer to or from an account the file does not list: one leg, against the placeholder that stands in for it.
        private mutating func placeholderTransfer(_ row: Row, counterpart: String, outgoing: Bool) throws {
            guard row.account.kind != .card, case let .account(own) = Self.binding(row.account) else { return try unpairedTransfer(row) }
            let amount = try Self.money(abs(row.transaction.amount))
            let other = ActualImportPlanner.accountID(named: counterpart)
            let id = Self.candidateID(row.id)
            let draft = try self.draft(row, kind: outgoing ? .transferOut : .transferIn, direction: outgoing ? .outflow : .inflow, amount: amount, includeMemo: true)
            let entry = LedgerEntry(
                id: ActualImportPlanner.entryID(forRow: row.id), kind: .transfer, occurredAtUnixMilliseconds: draft.occurredAt.unixMilliseconds,
                postings: [Posting(accountID: own, delta: outgoing ? try amount.negated() : amount), Posting(accountID: other, delta: outgoing ? amount : try amount.negated())],
                evidenceIDs: [ActualImportPlanner.evidenceID(forRow: row.id)]
            )
            try ready(id, [row.id], draft, entry)
        }

        private mutating func unpairedTransfer(_ row: Row) throws {
            let amount = try Self.money(abs(row.transaction.amount))
            let outgoing = row.transaction.amount < 0
            let draft = try self.draft(row, kind: outgoing ? .transferOut : .transferIn, direction: outgoing ? .outflow : .inflow, amount: amount, includeMemo: true)
            let id = Self.candidateID(row.id)
            try review(id, [row.id], draft, [.incompleteTransfer])
            note(id, row, title: nil, signed: row.transaction.amount, reasons: [.unpairedTransfer], inLedger: false)
        }

        // MARK: Settlement deposits

        private mutating func addSettlementDeposit(_ key: String, _ children: [Row]) throws {
            let sorted = children.sorted { $0.id < $1.id }
            let total = sorted.reduce(Int64(0)) { $0 + $1.transaction.amount }
            let amount = try Self.money(total)
            guard let first = sorted.first, case let .account(accountID) = Self.binding(first.account),
                  sorted.allSatisfy({ $0.account.name == first.account.name }) else { return }
            let evidence = sorted.map(\.id)
            let id = Self.candidateID(key)
            let entryID = ActualImportPlanner.entryID(forRow: key)
            // The sender's name is never read from a settlement deposit (Q6): only the store the deposit paid back is its name.
            let draft = try self.draft(first, kind: .deposit, direction: .inflow, amount: amount, includeMemo: false, includeImportedName: false)
            let entry = LedgerEntry(
                id: entryID, kind: .income, occurredAtUnixMilliseconds: draft.occurredAt.unixMilliseconds,
                postings: [Posting(accountID: accountID, delta: amount)], evidenceIDs: evidence.map(ActualImportPlanner.evidenceID(forRow:))
            )
            try ready(id, evidence, draft, entry)

            var links: [PlannedSettlement.Link] = []
            for child in sorted {
                guard let origin = Self.originID(of: child), let originEntry = expenseEntries[origin] else { break }
                links.append(PlannedSettlement.Link(rowID: child.id, originEntryID: originEntry, amount: try Self.money(child.transaction.amount)))
            }
            if links.count == sorted.count {
                settlements.append(PlannedSettlement(depositEntryID: entryID, occurredAtUnixMilliseconds: draft.occurredAt.unixMilliseconds, links: links))
            } else {
                note(id, first, title: draft.counterparty.merchantRaw, signed: total, reasons: [.settlementOriginMissing, .unclassifiedDeposit], inLedger: true)
            }
        }

        // MARK: Candidate construction

        private mutating func ready(
            _ id: TransactionCandidateID, _ rows: [String], _ draft: TransactionCandidateDraft, _ entry: LedgerEntry
        ) throws {
            candidates.append(try TransactionCandidate(
                id: id, evidenceIDs: rows.map(ActualImportPlanner.evidenceID(forRow:)), status: .ready, proposedEntry: entry,
                policyVersion: ImportPlan.policyVersion, sourceDraft: draft
            ))
        }

        private mutating func review(_ id: TransactionCandidateID, _ rows: [String], _ draft: TransactionCandidateDraft, _ issues: [CandidateIssue]) throws {
            candidates.append(try TransactionCandidate(
                id: id, evidenceIDs: rows.map(ActualImportPlanner.evidenceID(forRow:)), status: .needsReview, issues: issues,
                policyVersion: ImportPlan.policyVersion, sourceDraft: draft
            ))
        }

        /// Actual keeps only the day. Rows that look alike (same day, kind, direction and amount) get a few minutes apart so the
        /// ledger's duplicate check never takes a second bus fare for a repeat of the first.
        private mutating func draft(
            _ row: Row, kind: DraftEventKind, direction: TransactionDirection, amount: Money, includeMemo: Bool,
            includeImportedName: Bool = true
        ) throws -> TransactionCandidateDraft {
            // Not per account: a transfer one way and the same amount back the other way look alike to the duplicate check too.
            let key = "\(row.transaction.date)|\(kind.rawValue)|\(direction.rawValue)|\(amount.minorUnits)"
            let slot = slots[key, default: 0]
            slots[key] = slot + 1
            let time = row.day + Int64(min(slot, 30)) * 6 * 60_000
            let payee = row.transaction.payee?.trimmingCharacters(in: .whitespacesAndNewlines)
            let imported = includeImportedName ? row.transaction.importedPayee?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            let merchant = [payee, imported].compactMap { $0 }.first { !$0.isEmpty }
            let memo = includeMemo ? row.transaction.notes?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            return try TransactionCandidateDraft(
                rawNotificationID: ActualImportPlanner.evidenceID(forRow: row.id), parserID: "actual-import", parserVersion: "1", ruleID: "actual-v1",
                kind: kind, direction: direction, amount: amount,
                occurredAt: ObservedTimestamp(unixMilliseconds: time, precision: .day, source: .text),
                counterparty: DraftCounterparty(merchantRaw: merchant, memoRaw: (memo?.isEmpty ?? true) ? nil : memo),
                issues: merchant == nil ? [.merchantMissing] : [], confidence: .high
            )
        }

        private mutating func note(
            _ id: TransactionCandidateID, _ row: Row, title: String?, signed: Int64, reasons: [PendingReason], inLedger: Bool
        ) {
            guard !pending.contains(where: { $0.candidateID == id && $0.accountName == row.account.name }) else { return }
            let money = (try? Self.money(abs(signed))) ?? Money.zeroKRW
            pending.append(PendingImport(
                candidateID: id, accountName: row.account.name, title: title, amount: money, signedMinorUnits: signed,
                occurredAtUnixMilliseconds: row.day, reasons: reasons, inLedger: inLedger
            ))
        }

        /// What a notification would have called it.
        private static func title(_ draft: TransactionCandidateDraft) -> String? {
            [draft.counterparty.merchantRaw, draft.counterparty.memoRaw].compactMap { $0 }.first { !$0.isEmpty }
        }

        private mutating func warn(_ code: ImportWarning.Code, _ rowID: String?, _ detail: String) {
            warnings.append(ImportWarning(code: code, rowID: rowID, detail: detail))
        }

        // MARK: Helpers

        /// The account name after the arrow of a transfer mark (`→ 계좌`, `← 계좌`).
        static func counterpart(of transfer: String?) -> String? {
            guard let text = transfer?.trimmingCharacters(in: .whitespaces), let arrow = text.first, arrow == "→" || arrow == "←" else { return nil }
            let name = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }

        static func placeholder(_ name: String) -> ImportedAccount { ImportedAccount(name: name, kind: .bank) }

        static func candidateID(_ rowID: String) -> TransactionCandidateID { TransactionCandidateID(rawValue: "actual/" + rowID) }

        static func binding(_ account: ImportedAccount) -> ResolvedLedgerBinding {
            account.kind == .card ? .creditInstrument(ActualImportPlanner.instrumentID(named: account.name)) : .account(ActualImportPlanner.accountID(named: account.name))
        }

        static func money(_ minorUnits: Int64) throws -> Money { try Money(minorUnits: minorUnits, currency: ImportPlan.currency) }

        static func month(_ date: String) throws -> BudgetMonth {
            let parts = date.split(separator: "-").compactMap { Int($0) }
            return try BudgetMonth(year: parts.first ?? 0, month: parts.count > 1 ? parts[1] : 0)
        }

        /// The id after `원거래` in the note Actual's settlement flow wrote.
        static func originID(of row: Row) -> String? { token(after: "원거래", in: row.transaction.notes) }

        /// The deposit a settlement row was split from: the id after `입금거래`, else the row itself, when the note names an original purchase.
        static func depositKey(of row: Row) -> String? {
            guard originID(of: row) != nil else { return nil }
            return token(after: "입금거래", in: row.transaction.notes) ?? row.id
        }

        private static func token(after marker: String, in notes: String?) -> String? {
            guard let notes, let range = notes.range(of: marker) else { return nil }
            let rest = notes[range.upperBound...].drop(while: { $0 == " " || $0 == ":" })
            let token = rest.prefix(while: { !$0.isWhitespace && $0 != "·" })
            return token.isEmpty ? nil : String(token)
        }
    }
}

extension Money {
    fileprivate static var zeroKRW: Money { try! Money(minorUnits: 0, currency: "KRW") }
}
