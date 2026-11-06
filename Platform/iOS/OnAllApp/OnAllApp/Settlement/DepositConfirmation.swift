import NEOBudgetCalendar
import NEOBudgetCore

/// Answering "이 돈이 그 정산이 맞나요?" (`docs/ledger-behavior.md`, 정산 이후 결정 1·3·4·8). Nothing is linked until the user picks the request; this
/// only says how the deposit compares with what was still owed and records the user's choices: a short deposit closes the rest or leaves it open,
/// a larger one leaves its excess as a surplus (what the surplus counts as is the app setting's), and the sender's name can be remembered.
enum DepositConfirmation {
    enum Fit: Equatable {
        case exact
        /// Less than what is owed; `left` is still owed after it.
        case short(leftMinorUnits: Int64)
        /// More than what is owed by `extra`.
        case over(extraMinorUnits: Int64)
        /// The request has no exact amount; the deposit becomes it.
        case unknownAmount
    }

    enum ShortChoice: Equatable {
        /// Forgive the rest (탕감): the request is closed.
        case close
        /// Keep the request open for the rest. The default.
        case keepOpen
    }

    /// What is still owed on a receivable, `nil` while its amount is not known exactly.
    static func remaining(of obligation: Obligation, in life: LifeState) -> Int64? {
        obligation.amount.knowledge.knownValue.map { max(0, $0 - life.closedMinorUnits(for: obligation.id)) }
    }

    static func fit(_ deposit: LedgerDeposit, _ obligation: Obligation, in life: LifeState) -> Fit {
        guard let left = remaining(of: obligation, in: life) else { return .unknownAmount }
        let paid = deposit.amount.minorUnits
        if paid == left { return .exact }
        return paid < left ? .short(leftMinorUnits: left - paid) : .over(extraMinorUnits: paid - left)
    }

    /// A deposit that closes money owed both ways at once: the matcher's net proposal and its "받을 − 줄 = 입금" split. `nil` unless both
    /// directions are in it. Only offered; nothing is linked until the user confirms (`applyNetting`).
    static func netting(_ deposit: LedgerDeposit, from sender: PersonID?, in life: LifeState) -> (proposal: SettlementProposal, breakdown: NettingBreakdown)? {
        guard let sender, let transfer = try? ActualTransfer(
            transactionID: deposit.id, counterpartyID: sender, direction: .incoming,
            amount: deposit.amount, occurredAtUnixMilliseconds: deposit.occurredAtUnixMilliseconds
        ), case let .netMatch(proposal) = SettlementMatcher.match(transfer, in: life) else { return nil }
        let breakdown = proposal.nettingBreakdown(in: life)
        return breakdown.isNetted ? (proposal, breakdown) : nil
    }

    /// Closes both sides with the proposal the user confirmed.
    static func applyNetting(
        _ proposal: SettlementProposal, provenance: AssignmentProvenance, perform: (CalendarCommand) async -> CalendarCommandOutcome?,
        isolation: isolated (any Actor)? = #isolation
    ) async -> Bool {
        guard case .applied? = await perform(.applySettlement(ApplySettlementInput(proposal: proposal, provenance: provenance))) else { return false }
        return true
    }

    /// A short deposit from someone I have no registered payable to: it may be a netting I forgot to register, so ask before choosing.
    static func isUnexplainedShort(_ fit: Fit, counterparty: PersonID, in life: LifeState) -> Bool {
        guard case .short = fit else { return false }
        return !life.obligations.values.contains { $0.isSettleable && $0.direction == .payable && $0.counterpartyID == counterparty }
    }

    /// Whether the sender's name in the notification already is this person's name or alias; if not, the user may want it remembered.
    static func isNewAlias(_ deposit: LedgerDeposit, for person: Person) -> Bool {
        guard let title = deposit.title.flatMap(ActivityEditing.cleanName) else { return false }
        return !person.matches(name: title)
    }

    /// Records the deposit against the request the user picked. Returns `false` at the first step that was refused (what was recorded before it
    /// stays; a settlement is one command, so it is all or nothing).
    static func apply(
        _ deposit: LedgerDeposit, to obligation: Obligation, life: LifeState, shortChoice: ShortChoice, rememberAlias: Bool,
        provenance: AssignmentProvenance, perform: (CalendarCommand) async -> CalendarCommandOutcome?,
        isolation: isolated (any Actor)? = #isolation
    ) async -> Bool {
        guard let transfer = try? ActualTransfer(
            transactionID: deposit.id, counterpartyID: obligation.counterpartyID, direction: .incoming,
            amount: deposit.amount, occurredAtUnixMilliseconds: deposit.occurredAtUnixMilliseconds
        ) else { return false }
        let paid = deposit.amount.minorUnits
        let command: CalendarCommand
        var closing: ObligationID?
        switch fit(deposit, obligation, in: life) {
        case .unknownAmount:
            command = .recordManualSettlement(ManualSettlementInput(
                transfer: transfer, applications: [ProposedApplication(obligationID: obligation.id, appliedMinorUnits: paid)],
                confirmedAmounts: [obligation.id: paid], provenance: provenance
            ))
        case .exact:
            command = proposal(transfer, obligation.id, applied: paid, provenance: provenance)
        case let .short(left):
            command = proposal(
                transfer, obligation.id, applied: paid, partial: true,
                residual: ProposedResidual(direction: .shortfall, minorUnits: left, obligationID: obligation.id), provenance: provenance
            )
            if shortChoice == .close { closing = obligation.id }
        case let .over(extra):
            command = proposal(
                transfer, obligation.id, applied: paid - extra,
                residual: ProposedResidual(direction: .surplus, minorUnits: extra), provenance: provenance
            )
        }
        guard case let .applied(done)? = await perform(command) else { return false }
        if let closing, let settlement = done.settlementID {
            let residual = ResidualID(rawValue: settlement.rawValue + "-shortfall-" + closing.rawValue)
            guard case .applied? = await perform(.classifyResidual(ClassifyResidualInput(residualID: residual, classification: .waived, provenance: provenance))) else { return false }
        }
        if rememberAlias, let person = life.persons[obligation.counterpartyID], let title = deposit.title.flatMap(ActivityEditing.cleanName) {
            _ = await perform(.upsertPerson(person.remembering(alias: title)))
        }
        return true
    }

    private static func proposal(
        _ transfer: ActualTransfer, _ obligation: ObligationID, applied: Int64, partial: Bool = false, residual: ProposedResidual? = nil,
        provenance: AssignmentProvenance
    ) -> CalendarCommand {
        .applySettlement(ApplySettlementInput(
            proposal: SettlementProposal(
                transfer: transfer, applications: [ProposedApplication(obligationID: obligation, appliedMinorUnits: applied)],
                inferences: [], requestID: nil, isPartial: partial, residuals: residual.map { [$0] } ?? []
            ),
            provenance: provenance
        ))
    }

    /// A gathering nobody was asked for: the deposit itself says what the sender owed. Makes the sender if new, the request for the whole deposit,
    /// and the settlement that pays it.
    static func applyToGathering(
        _ deposit: LedgerDeposit, activity: ActivityID, senderName: String, life: LifeState, provenance: AssignmentProvenance,
        newID: (String) -> String, perform: (CalendarCommand) async -> CalendarCommandOutcome?,
        isolation: isolated (any Actor)? = #isolation
    ) async -> Bool {
        var personID = life.persons.values.filter { !$0.isSelf && $0.matches(name: senderName) }.min { $0.id < $1.id }?.id
        if personID == nil {
            let person = Person(id: PersonID(rawValue: newID("person")), displayName: senderName)
            guard case .applied? = await perform(.upsertPerson(person)) else { return false }
            personID = person.id
        }
        guard let personID else { return false }
        let input = CreateObligationInput(
            counterpartyID: personID, activity: .activity(activity), direction: .receivable, currency: deposit.amount.currency,
            amount: .exact(deposit.amount.minorUnits), label: SettlementLabel.request, provenance: provenance
        )
        guard case let .applied(created)? = await perform(.createObligation(input)), let obligationID = created.obligationID,
              let transfer = try? ActualTransfer(
                  transactionID: deposit.id, counterpartyID: personID, direction: .incoming,
                  amount: deposit.amount, occurredAtUnixMilliseconds: deposit.occurredAtUnixMilliseconds
              ) else { return false }
        let settle = ManualSettlementInput(
            transfer: transfer, applications: [ProposedApplication(obligationID: obligationID, appliedMinorUnits: deposit.amount.minorUnits)],
            provenance: provenance
        )
        guard case .applied? = await perform(.recordManualSettlement(settle)) else { return false }
        return true
    }
}
