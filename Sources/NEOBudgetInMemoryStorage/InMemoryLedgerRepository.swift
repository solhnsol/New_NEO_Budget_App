import NEOBudgetCore

/// A deterministic reference adapter. A commit validates only the new entry, against the aggregates of what is already
/// accepted, before anything changes, which makes every commit atomic from the caller's point of view and keeps the
/// cost of a commit independent of how many entries the ledger holds.
public struct InMemoryLedgerRepository: LedgerRepository {
    private let configuration: LedgerConfiguration
    private let accounts: [AccountID: Account]
    private let instruments: [CreditInstrumentID: CreditInstrument]
    private var entries: [LedgerEntry] = []
    private var entryIndex: [LedgerEntryID: Int] = [:]
    private var revision: UInt64 = 0

    // What the accepted entries add up to, kept current by every commit.
    private var balances: [AccountID: Money]
    private var liabilities: [CreditInstrumentID: Money] = [:]
    private var expenses: [BudgetMonth: Money] = [:]
    private var returns: [BudgetMonth: Money] = [:]
    private var summaries: [BudgetMonth: MonthlyBudgetSummary] = [:]
    private var adjustedMinorUnits: [LedgerEntryID: Int64] = [:]
    private var evidenceOwners: [String: LedgerEntryID] = [:]
    private var reversed = Set<LedgerEntryID>()

    public init(configuration: LedgerConfiguration) throws {
        try Self.validate(configuration)
        self.configuration = configuration
        accounts = Dictionary(uniqueKeysWithValues: configuration.accounts.map { ($0.id, $0) })
        instruments = Dictionary(uniqueKeysWithValues: configuration.creditInstruments.map { ($0.id, $0) })
        balances = Dictionary(uniqueKeysWithValues: configuration.accounts.map { ($0.id, $0.openingBalance) })
        for instrument in configuration.creditInstruments {
            liabilities[instrument.id] = try Money(minorUnits: 0, currency: instrument.currency)
        }
    }

    /// How many commits the ledger has accepted.
    public var currentRevision: UInt64 { revision }

    /// The accepted entry with this ID, if there is one.
    public func entry(withID id: LedgerEntryID) -> LedgerEntry? {
        entryIndex[id].map { entries[$0] }
    }

    public func snapshot() throws -> LedgerSnapshot {
        LedgerSnapshot(
            revision: revision,
            entries: entries,
            accountBalances: balances,
            outstandingLiabilities: liabilities,
            monthlyBudgets: summaries
        )
    }

    public mutating func commit(
        _ entry: LedgerEntry,
        expectedRevision: UInt64
    ) throws -> LedgerCommitResult {
        if let index = entryIndex[entry.id] {
            guard entries[index] == entry else { throw LedgerStorageError.conflictingEntry(entry.id) }
            return .alreadyCommitted(revision: revision)
        }
        guard expectedRevision == revision else {
            throw LedgerStorageError.staleRevision(expected: expectedRevision, actual: revision)
        }
        guard revision < UInt64.max else { throw LedgerStorageError.revisionOverflow }

        let effect: Effect
        do {
            effect = try validated(entry)
        } catch let error as LedgerValidationError {
            throw LedgerStorageError.invalidEntry(error)
        } catch is MoneyError {
            throw LedgerStorageError.invalidEntry(.arithmeticOverflow)
        }

        for (account, balance) in effect.balances { balances[account] = balance }
        for (instrument, owed) in effect.liabilities { liabilities[instrument] = owed }
        if let (month, total) = effect.expense { expenses[month] = total }
        if let (month, total) = effect.returned { returns[month] = total }
        if let (month, summary) = effect.summary { summaries[month] = summary }
        if let (original, total) = effect.adjusted { adjustedMinorUnits[original] = total }
        for evidenceID in entry.evidenceIDs { evidenceOwners[evidenceID] = entry.id }
        if let target = entry.reverses { reversed.insert(target) }
        entryIndex[entry.id] = entries.count
        entries.append(entry)
        revision += 1
        return .committed(revision: revision)
    }

    /// A point `rollback(to:)` can return to. Taken before a group of commits that must succeed or fail together.
    public struct Checkpoint {
        fileprivate let revision: UInt64
        fileprivate let entryCount: Int
        fileprivate let balances: [AccountID: Money]
        fileprivate let liabilities: [CreditInstrumentID: Money]
        fileprivate let expenses: [BudgetMonth: Money]
        fileprivate let returns: [BudgetMonth: Money]
        fileprivate let summaries: [BudgetMonth: MonthlyBudgetSummary]
    }

    public func checkpoint() -> Checkpoint {
        Checkpoint(revision: revision, entryCount: entries.count, balances: balances, liabilities: liabilities,
                   expenses: expenses, returns: returns, summaries: summaries)
    }

    /// Undoes every commit made after `checkpoint`. The small per-account and per-month totals are restored from the
    /// checkpoint; the per-entry indexes are undone from the entries being removed.
    public mutating func rollback(to checkpoint: Checkpoint) {
        while entries.count > checkpoint.entryCount {
            let entry = entries.removeLast()
            entryIndex[entry.id] = nil
            for evidenceID in entry.evidenceIDs { evidenceOwners[evidenceID] = nil }
            if let target = entry.reverses { reversed.remove(target) }
            if let link = entry.adjustment, let amount = entry.budgetImpact?.amount.minorUnits {
                let remaining = adjustedMinorUnits[link.originalEntryID, default: 0] - amount
                adjustedMinorUnits[link.originalEntryID] = remaining == 0 ? nil : remaining
            }
        }
        revision = checkpoint.revision
        balances = checkpoint.balances
        liabilities = checkpoint.liabilities
        expenses = checkpoint.expenses
        returns = checkpoint.returns
        summaries = checkpoint.summaries
    }

    /// What one accepted entry changes, worked out before anything is changed.
    private struct Effect {
        var balances: [AccountID: Money] = [:]
        var liabilities: [CreditInstrumentID: Money] = [:]
        var expense: (BudgetMonth, Money)?
        var returned: (BudgetMonth, Money)?
        var summary: (BudgetMonth, MonthlyBudgetSummary)?
        var adjusted: (LedgerEntryID, Int64)?
    }

    private static func validate(_ configuration: LedgerConfiguration) throws {
        var accountIDs = Set<AccountID>()
        for account in configuration.accounts {
            guard !account.id.rawValue.isEmpty else {
                throw LedgerStorageError.invalidConfiguration(.emptyIdentifier(entity: "account"))
            }
            guard accountIDs.insert(account.id).inserted else {
                throw LedgerStorageError.invalidConfiguration(
                    .duplicateIdentifier(entity: "account", id: account.id.rawValue)
                )
            }
        }

        var instrumentIDs = Set<CreditInstrumentID>()
        for instrument in configuration.creditInstruments {
            guard !instrument.id.rawValue.isEmpty else {
                throw LedgerStorageError.invalidConfiguration(.emptyIdentifier(entity: "creditInstrument"))
            }
            guard instrumentIDs.insert(instrument.id).inserted else {
                throw LedgerStorageError.invalidConfiguration(
                    .duplicateIdentifier(entity: "creditInstrument", id: instrument.id.rawValue)
                )
            }
            do {
                _ = try Money(minorUnits: 0, currency: instrument.currency)
            } catch {
                throw LedgerStorageError.invalidConfiguration(.invalidCurrency(instrument.currency))
            }
        }
    }

    private func validated(_ entry: LedgerEntry) throws -> Effect {
        try Self.validateEntryShape(entry)
        for evidenceID in entry.evidenceIDs {
            if let owner = evidenceOwners[evidenceID] {
                throw LedgerValidationError.evidenceAlreadyUsed(id: evidenceID, entryID: owner)
            }
        }

        var effect = Effect()
        var entryCurrency: String?
        func acceptCurrency(_ currency: String) throws {
            if let expected = entryCurrency, expected != currency {
                throw LedgerValidationError.currencyMismatch(expected: expected, actual: currency)
            }
            entryCurrency = currency
        }

        for posting in entry.postings {
            guard let account = accounts[posting.accountID] else {
                throw LedgerValidationError.unknownAccount(posting.accountID)
            }
            guard account.isActive else {
                throw LedgerValidationError.inactiveAccount(posting.accountID)
            }
            guard account.openingBalance.currency == posting.delta.currency else {
                throw LedgerValidationError.currencyMismatch(
                    expected: account.openingBalance.currency,
                    actual: posting.delta.currency
                )
            }
            try acceptCurrency(posting.delta.currency)
            effect.balances[posting.accountID] = try balances[posting.accountID]!.adding(posting.delta)
        }

        for change in entry.liabilityChanges {
            guard let instrument = instruments[change.instrumentID] else {
                throw LedgerValidationError.unknownCreditInstrument(change.instrumentID)
            }
            guard instrument.isActive else {
                throw LedgerValidationError.inactiveCreditInstrument(change.instrumentID)
            }
            guard instrument.currency == change.delta.currency else {
                throw LedgerValidationError.currencyMismatch(
                    expected: instrument.currency,
                    actual: change.delta.currency
                )
            }
            try acceptCurrency(change.delta.currency)
            effect.liabilities[change.instrumentID] = try liabilities[change.instrumentID]!.adding(change.delta)
        }

        var month: BudgetMonth?
        var expense: Money?, returned: Money?
        if let impact = entry.budgetImpact {
            try acceptCurrency(impact.amount.currency)
            month = impact.attributedMonth
            expense = expenses[impact.attributedMonth]
            returned = returns[impact.attributedMonth]
            if impact.kind == .expense {
                expense = try Self.add(impact.amount, to: expense)
                effect.expense = (impact.attributedMonth, expense!)
            } else {
                returned = try Self.add(impact.amount, to: returned)
                effect.returned = (impact.attributedMonth, returned!)
            }
        }

        if let link = entry.adjustment {
            guard let original = entryIndex[link.originalEntryID].map({ entries[$0] }) else {
                throw LedgerValidationError.originalEntryNotFound(link.originalEntryID)
            }
            guard original.kind == .expense, let originalImpact = original.budgetImpact,
                  originalImpact.kind == .expense else {
                throw LedgerValidationError.adjustmentTargetIsNotExpense(link.originalEntryID)
            }
            guard entry.budgetImpact?.attributedMonth == originalImpact.attributedMonth else {
                throw LedgerValidationError.adjustmentMonthMismatch
            }
            let prior = adjustedMinorUnits[link.originalEntryID, default: 0]
            let amount = entry.budgetImpact!.amount.minorUnits
            let (total, overflow) = prior.addingReportingOverflow(amount)
            guard !overflow, total <= originalImpact.amount.minorUnits else {
                throw LedgerValidationError.adjustmentExceedsOriginal(link.originalEntryID)
            }
            effect.adjusted = (link.originalEntryID, total)
        }

        if let target = entry.reverses {
            // Only an income is reversed for now (a transfer leg recorded before the transfer was known), and only once.
            guard let original = entryIndex[target].map({ entries[$0] }), original.kind == .income, original.reverses == nil,
                  original.liabilityChanges.isEmpty,
                  Set(original.postings.map(\.accountID)) == Set(entry.postings.map(\.accountID)),
                  try original.postings.allSatisfy({ posting in
                      try entry.postings.first { $0.accountID == posting.accountID }?.delta == posting.delta.negated()
                  }) else {
                throw LedgerValidationError.reversalTargetInvalid(target)
            }
            guard !reversed.contains(target) else { throw LedgerValidationError.alreadyReversed(target) }
        }

        if let month {
            let sample = expense ?? returned!
            let spent = try expense ?? Money(minorUnits: 0, currency: sample.currency)
            let paidBack = try returned ?? Money(minorUnits: 0, currency: sample.currency)
            effect.summary = (month, MonthlyBudgetSummary(
                expense: spent, returns: paidBack, netExpense: try spent.adding(paidBack.negated())
            ))
        }
        return effect
    }

    private static func validateEntryShape(_ entry: LedgerEntry) throws {
        guard !entry.id.rawValue.isEmpty else {
            throw LedgerValidationError.emptyIdentifier(entity: "ledgerEntry")
        }
        guard Set(entry.postings.map(\.accountID)).count == entry.postings.count else {
            throw LedgerValidationError.invalidEntryShape(kind: entry.kind)
        }
        guard Set(entry.liabilityChanges.map(\.instrumentID)).count == entry.liabilityChanges.count else {
            throw LedgerValidationError.invalidEntryShape(kind: entry.kind)
        }
        guard Set(entry.evidenceIDs).count == entry.evidenceIDs.count,
              entry.evidenceIDs.allSatisfy({ !$0.isEmpty }) else {
            throw LedgerValidationError.invalidEntryShape(kind: entry.kind)
        }
        guard entry.postings.allSatisfy({ $0.delta.minorUnits != 0 }) else {
            throw LedgerValidationError.zeroDelta(entity: "posting")
        }
        guard entry.liabilityChanges.allSatisfy({ $0.delta.minorUnits != 0 }) else {
            throw LedgerValidationError.zeroDelta(entity: "liabilityChange")
        }
        if let impact = entry.budgetImpact, impact.amount.minorUnits <= 0 {
            throw LedgerValidationError.invalidBudgetImpact
        }

        guard (entry.kind == .reversal) == (entry.reverses != nil) else {
            throw LedgerValidationError.invalidEntryShape(kind: entry.kind)
        }
        switch entry.kind {
        case .reversal:
            guard entry.adjustment == nil, entry.budgetImpact == nil, entry.liabilityChanges.isEmpty, !entry.postings.isEmpty else {
                throw LedgerValidationError.invalidEntryShape(kind: entry.kind)
            }
        case .expense:
            guard entry.adjustment == nil,
                  let impact = entry.budgetImpact,
                  impact.kind == .expense,
                  entry.postings.allSatisfy({ $0.delta.minorUnits < 0 }),
                  entry.liabilityChanges.allSatisfy({ $0.delta.minorUnits > 0 }),
                  !entry.postings.isEmpty || !entry.liabilityChanges.isEmpty,
                  magnitudesEqual(
                    entry.postings.map { $0.delta.minorUnits } +
                        entry.liabilityChanges.map { $0.delta.minorUnits },
                    impact.amount.minorUnits
                  ) else {
                throw LedgerValidationError.invalidEntryShape(kind: entry.kind)
            }
        case .income:
            guard entry.adjustment == nil, entry.budgetImpact == nil,
                  !entry.postings.isEmpty,
                  entry.postings.allSatisfy({ $0.delta.minorUnits > 0 }),
                  entry.liabilityChanges.isEmpty else {
                throw LedgerValidationError.invalidEntryShape(kind: entry.kind)
            }
        case .transfer:
            guard entry.adjustment == nil, entry.budgetImpact == nil,
                  entry.liabilityChanges.isEmpty, entry.postings.count == 2,
                  entry.postings[0].delta.currency == entry.postings[1].delta.currency,
                  (try? entry.postings[0].delta.adding(entry.postings[1].delta).minorUnits) == 0 else {
                throw LedgerValidationError.invalidEntryShape(kind: entry.kind)
            }
        case .cardPayment:
            guard entry.adjustment == nil, entry.budgetImpact == nil,
                  !entry.postings.isEmpty, !entry.liabilityChanges.isEmpty,
                  entry.postings.allSatisfy({ $0.delta.minorUnits < 0 }),
                  entry.liabilityChanges.allSatisfy({ $0.delta.minorUnits < 0 }),
                  magnitudesEqual(
                    entry.postings.map { $0.delta.minorUnits },
                    entry.liabilityChanges.map { $0.delta.minorUnits }
                  ) else {
                throw LedgerValidationError.invalidEntryShape(kind: entry.kind)
            }
        case .adjustment:
            guard entry.adjustment != nil,
                  let impact = entry.budgetImpact,
                  impact.kind == .return,
                  entry.postings.allSatisfy({ $0.delta.minorUnits > 0 }),
                  entry.liabilityChanges.allSatisfy({ $0.delta.minorUnits < 0 }),
                  !entry.postings.isEmpty || !entry.liabilityChanges.isEmpty,
                  magnitudesEqual(
                    entry.postings.map { $0.delta.minorUnits } +
                        entry.liabilityChanges.map { $0.delta.minorUnits },
                    impact.amount.minorUnits
                  ) else {
                throw LedgerValidationError.invalidEntryShape(kind: entry.kind)
            }
        }
    }

    private static func magnitudesEqual(_ values: [Int64], _ expected: Int64) -> Bool {
        magnitudeSum(values) == expected
    }

    private static func magnitudesEqual(_ left: [Int64], _ right: [Int64]) -> Bool {
        guard let leftSum = magnitudeSum(left), let rightSum = magnitudeSum(right) else {
            return false
        }
        return leftSum == rightSum
    }

    private static func magnitudeSum(_ values: [Int64]) -> Int64? {
        var total: Int64 = 0
        for value in values {
            let magnitude: Int64
            if value < 0 {
                let (positive, overflow) = Int64.zero.subtractingReportingOverflow(value)
                guard !overflow else { return nil }
                magnitude = positive
            } else {
                magnitude = value
            }
            let (sum, overflow) = total.addingReportingOverflow(magnitude)
            guard !overflow else { return nil }
            total = sum
        }
        return total
    }

    private static func add(_ amount: Money, to existing: Money?) throws -> Money {
        guard let existing else { return amount }
        return try existing.adding(amount)
    }
}
