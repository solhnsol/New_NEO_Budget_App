import NEOBudgetCore

/// A deterministic reference adapter. It validates a complete candidate state before replacing
/// the current state, which makes every commit atomic from the caller's point of view.
public struct InMemoryLedgerRepository: LedgerRepository {
    private let configuration: LedgerConfiguration
    private var entries: [LedgerEntry] = []
    private var revision: UInt64 = 0

    public init(configuration: LedgerConfiguration) throws {
        try Self.validate(configuration)
        self.configuration = configuration
    }

    public func snapshot() throws -> LedgerSnapshot {
        try Self.makeSnapshot(configuration: configuration, entries: entries, revision: revision)
    }

    public mutating func commit(
        _ entry: LedgerEntry,
        expectedRevision: UInt64
    ) throws -> LedgerCommitResult {
        if let existing = entries.first(where: { $0.id == entry.id }) {
            guard existing == entry else { throw LedgerStorageError.conflictingEntry(entry.id) }
            return .alreadyCommitted(revision: revision)
        }
        guard expectedRevision == revision else {
            throw LedgerStorageError.staleRevision(expected: expectedRevision, actual: revision)
        }
        guard revision < UInt64.max else { throw LedgerStorageError.revisionOverflow }

        let candidate = entries + [entry]
        do {
            _ = try Self.makeSnapshot(
                configuration: configuration,
                entries: candidate,
                revision: revision + 1
            )
        } catch let error as LedgerValidationError {
            throw LedgerStorageError.invalidEntry(error)
        } catch is MoneyError {
            throw LedgerStorageError.invalidEntry(.arithmeticOverflow)
        }

        entries = candidate
        revision += 1
        return .committed(revision: revision)
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

    private static func makeSnapshot(
        configuration: LedgerConfiguration,
        entries: [LedgerEntry],
        revision: UInt64
    ) throws -> LedgerSnapshot {
        let accounts = Dictionary(uniqueKeysWithValues: configuration.accounts.map { ($0.id, $0) })
        let instruments = Dictionary(
            uniqueKeysWithValues: configuration.creditInstruments.map { ($0.id, $0) }
        )
        var balances = Dictionary(
            uniqueKeysWithValues: configuration.accounts.map { ($0.id, $0.openingBalance) }
        )
        var liabilities: [CreditInstrumentID: Money] = [:]
        for instrument in configuration.creditInstruments {
            liabilities[instrument.id] = try Money(minorUnits: 0, currency: instrument.currency)
        }

        var expenses: [BudgetMonth: Money] = [:]
        var returns: [BudgetMonth: Money] = [:]
        var acceptedEntries: [LedgerEntryID: LedgerEntry] = [:]
        var adjustedMinorUnits: [LedgerEntryID: Int64] = [:]
        var evidenceOwners: [String: LedgerEntryID] = [:]

        for entry in entries {
            try validateEntryShape(entry)
            for evidenceID in entry.evidenceIDs {
                if let owner = evidenceOwners[evidenceID] {
                    throw LedgerValidationError.evidenceAlreadyUsed(id: evidenceID, entryID: owner)
                }
                evidenceOwners[evidenceID] = entry.id
            }

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
                balances[posting.accountID] = try balances[posting.accountID]!.adding(posting.delta)
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
                liabilities[change.instrumentID] = try liabilities[change.instrumentID]!.adding(change.delta)
            }

            if let impact = entry.budgetImpact {
                try acceptCurrency(impact.amount.currency)
                if impact.kind == .expense {
                    expenses[impact.attributedMonth] = try add(
                        impact.amount, to: expenses[impact.attributedMonth]
                    )
                } else {
                    returns[impact.attributedMonth] = try add(
                        impact.amount, to: returns[impact.attributedMonth]
                    )
                }
            }

            if let link = entry.adjustment {
                guard let original = acceptedEntries[link.originalEntryID] else {
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
                adjustedMinorUnits[link.originalEntryID] = total
            }

            acceptedEntries[entry.id] = entry
        }

        var summaries: [BudgetMonth: MonthlyBudgetSummary] = [:]
        for month in Set(expenses.keys).union(returns.keys) {
            let sample = expenses[month] ?? returns[month]!
            let expense = try expenses[month] ?? Money(minorUnits: 0, currency: sample.currency)
            let returned = try returns[month] ?? Money(minorUnits: 0, currency: sample.currency)
            let net = try expense.adding(returned.negated())
            summaries[month] = MonthlyBudgetSummary(
                expense: expense, returns: returned, netExpense: net
            )
        }

        return LedgerSnapshot(
            revision: revision,
            entries: entries,
            accountBalances: balances,
            outstandingLiabilities: liabilities,
            monthlyBudgets: summaries
        )
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

        switch entry.kind {
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
