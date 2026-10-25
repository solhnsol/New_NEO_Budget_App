import NEOBudgetCore

// What happens after a settlement is asked for (`docs/ledger-behavior.md`, 정산 이후): who still owes what and for how long, whether a
// deposit is worth a question, what a changed total adds to a request, how much of an event is really mine, and what a surplus is. All pure
// reads of `LifeState`; nothing here records anything. Deposits are never linked automatically: at most they are worth asking about.

public enum SettlementLabel {
    public static let request = "정산"
    public static let additional = "추가 정산"
    public static let expected = "정산 예정"
}

// MARK: Who owes what

/// One person's open settlements in one currency. Amounts count only what is known; an open obligation whose amount is not known is counted in
/// `unknownOpenCount` and adds nothing.
public struct PersonSettlementSummary: Hashable, Sendable {
    public let personID: PersonID
    public let currency: String
    /// They owe me, still open.
    public let receivableMinorUnits: Int64
    /// I owe them, still open.
    public let payableMinorUnits: Int64
    public let unknownOpenCount: Int
    public let oldestOpenAtUnixMilliseconds: Int64?
    /// Something they owe me has been open longer than the limit given to `settlementSummaries`.
    public let isOverdue: Bool

    public var netMinorUnits: Int64 { receivableMinorUnits - payableMinorUnits }
}

extension LifeState {
    /// Open settlements by person, oldest first. `overdueAfterDays`: how long a receivable may stay open before it is marked (a display marker only).
    public func settlementSummaries(nowUnixMilliseconds: Int64, overdueAfterDays: Int = 14) -> [PersonSettlementSummary] {
        struct Key: Hashable { let person: PersonID; let currency: String }
        var open: [Key: [Obligation]] = [:]
        for obligation in obligations.values where obligation.isSettleable {
            open[Key(person: obligation.counterpartyID, currency: obligation.currency), default: []].append(obligation)
        }
        let limit = Int64(overdueAfterDays) * 86_400_000
        return open.map { key, items in
            var receivable: Int64 = 0, payable: Int64 = 0, unknown = 0
            for obligation in items {
                guard let value = obligation.amount.knowledge.knownValue else { unknown += 1; continue }
                let remaining = max(0, value - closedMinorUnits(for: obligation.id))
                if obligation.direction == .receivable { receivable += remaining } else { payable += remaining }
            }
            let oldest = items.map(\.createdAtUnixMilliseconds).min()
            let overdue = items.contains { $0.direction == .receivable && nowUnixMilliseconds - $0.createdAtUnixMilliseconds > limit }
            return PersonSettlementSummary(
                personID: key.person, currency: key.currency, receivableMinorUnits: receivable, payableMinorUnits: payable,
                unknownOpenCount: unknown, oldestOpenAtUnixMilliseconds: oldest, isOverdue: overdue
            )
        }
        .sorted { ($0.oldestOpenAtUnixMilliseconds ?? .max, $0.personID.rawValue) < ($1.oldestOpenAtUnixMilliseconds ?? .max, $1.personID.rawValue) }
    }
}

// MARK: A deposit is a question only when something is waiting

public enum DepositReview: Equatable, Sendable {
    /// Something to settle is open: ask whether this money is for it. Candidates are open requests (the sender's first, then oldest first) and
    /// gatherings with people but no request yet. Answering is the user's; nothing is linked until they say so.
    case askToConfirm(obligations: [ObligationID], gatherings: [ActivityID])
    /// Nothing is waiting: it may just be money someone sent. No question.
    case leave
}

extension LifeState {
    /// `sender`: the person the deposit came from, when known. `currency`: the deposit's. `recentActivities`: restricts which request-less gatherings
    /// count (the caller passes the recent ones; with `nil` every one counts).
    public func depositReview(from sender: PersonID?, currency: String, recentActivities: Set<ActivityID>? = nil) -> DepositReview {
        let open = obligations.values
            .filter { $0.isSettleable && $0.direction == .receivable && $0.currency == currency }
            .sorted {
                let (left, right) = ($0.counterpartyID == sender, $1.counterpartyID == sender)
                if left != right { return left }
                return ($0.createdAtUnixMilliseconds, $0.id) < ($1.createdAtUnixMilliseconds, $1.id)
            }
        let asked = Set(obligations.values.filter { $0.status != .cancelled }.compactMap(\.activityID))
        let gatherings = activities.values
            .filter { activity in
                guard !asked.contains(activity.id), recentActivities?.contains(activity.id) ?? true else { return false }
                guard activity.participants.contains(where: { persons[$0.personID]?.isSelf == false }) else { return false }
                return allocations(forActivity: activity.id).contains { allocationSets[$0.transactionID]?.flow == .spend }
            }
            .map(\.id)
            .sorted()
        return open.isEmpty && gatherings.isEmpty ? .leave : .askToConfirm(obligations: open.map(\.id), gatherings: gatherings)
    }
}

// MARK: A changed total asks for the difference only

public struct AdditionalRequestDraft: Hashable, Sendable {
    public let counterpartyID: PersonID
    public let activityID: ActivityID
    public let currency: String
    public let deltaMinorUnits: Int64
}

extension LifeState {
    /// What each person has not yet been asked for, now that the component says more: its share today minus everything already asked of them for
    /// this activity (cancelled requests excluded, settled ones included). Requests already made are never changed, and a person whose share fell
    /// gets nothing. Only for the user paying (receivables).
    public func additionalRequests(forComponent id: ExpenseComponentID) throws -> [AdditionalRequestDraft] {
        guard let component = components[id] else { throw LifeValidationError.unknownComponent(id) }
        let derivation = try deriveObligations(forComponent: id)
        let labels = [SettlementLabel.request, SettlementLabel.additional, component.label]
        return derivation.drafts.compactMap { draft in
            guard draft.direction == .receivable, let share = draft.amount.knownValue else { return nil }
            let asked = obligations.values
                .filter {
                    $0.counterpartyID == draft.counterpartyID && $0.activityID == component.activityID && $0.direction == .receivable
                        && $0.status != .cancelled && $0.currency == draft.currency && labels.contains($0.label ?? "")
                }
                .reduce(Int64(0)) { $0 + ($1.amount.knowledge.knownValue ?? 0) }
            guard share > asked else { return nil }
            return AdditionalRequestDraft(counterpartyID: draft.counterpartyID, activityID: component.activityID, currency: draft.currency, deltaMinorUnits: share - asked)
        }
        .sorted { $0.counterpartyID < $1.counterpartyID }
    }
}

extension AdditionalRequestDraft {
    public func input(provenance: AssignmentProvenance) -> CreateObligationInput {
        CreateObligationInput(
            counterpartyID: counterpartyID, activity: .activity(activityID), direction: .receivable, currency: currency,
            amount: .exact(deltaMinorUnits), label: SettlementLabel.additional, provenance: provenance
        )
    }
}

// MARK: Money I will send, registered ahead

public enum ExpectedPaymentLink {
    /// When the user sends money to someone they registered an expected payment to (`direction: .payable`, amount exact or unknown), the transfer
    /// settles it without asking. Only a unique explanation that touches nothing but money I owe is returned; anything else (an obligation owed to
    /// me in the mix, an ambiguous or leftover amount) is for the user to decide.
    public static func autoProposal(for transfer: ActualTransfer, in life: LifeState) -> SettlementProposal? {
        guard transfer.direction == .outgoing else { return nil }
        let proposal: SettlementProposal
        switch SettlementMatcher.match(transfer, in: life) {
        case let .exactMatch(found), let .inferredUniqueSolution(found), let .netMatch(found): proposal = found
        default: return nil
        }
        let allOwed = proposal.applications.allSatisfy { life.obligations[$0.obligationID]?.direction == .payable }
        return allOwed && proposal.residuals.isEmpty ? proposal : nil
    }
}

// MARK: How much of an event is mine

/// What an event cost me once what others paid back (or still owe) is taken off. `pending` is asked but not yet received: it is already out of
/// `myShare`, and the screen says "정산 대기 중" next to it. Settlements the user waived stay in `myShare`.
public struct ActivityShare: Hashable, Sendable {
    public let activityID: ActivityID
    public let currency: String
    public let spentMinorUnits: Int64
    public let refundedMinorUnits: Int64
    public let receivedMinorUnits: Int64
    public let pendingMinorUnits: Int64
    /// Some linked amount, or some open request, has no exact value yet, so the numbers above are a floor.
    public let hasUnknown: Bool

    public var myShareMinorUnits: Int64 { spentMinorUnits - refundedMinorUnits - receivedMinorUnits - pendingMinorUnits }
    public var isPending: Bool { pendingMinorUnits > 0 }
}

extension LifeState {
    public func activityShares() -> [ActivityShare] {
        struct Key: Hashable { let activity: ActivityID; let currency: String }
        struct Sums { var spent: Int64 = 0, refunded: Int64 = 0, received: Int64 = 0, pending: Int64 = 0, unknown = false }
        var sums: [Key: Sums] = [:]
        for set in allocationSets.values {
            for allocation in set.allocations {
                guard let activity = allocation.activityID else { continue }
                var entry = sums[Key(activity: activity, currency: allocation.amount.currency), default: Sums()]
                if let value = allocation.amount.knowledge.knownValue {
                    if set.flow == .spend { entry.spent += value } else { entry.refunded += value }
                } else {
                    entry.unknown = true
                }
                sums[Key(activity: activity, currency: allocation.amount.currency)] = entry
            }
        }
        for obligation in obligations.values where obligation.direction == .receivable && obligation.status != .cancelled {
            guard let activity = obligation.activityID else { continue }
            let key = Key(activity: activity, currency: obligation.currency)
            guard var entry = sums[key] else { continue }
            let applied = appliedMinorUnits(for: obligation.id)
            entry.received += applied
            if let value = obligation.amount.knowledge.knownValue {
                entry.pending += max(0, value - closedMinorUnits(for: obligation.id))
            } else if obligation.isSettleable {
                entry.unknown = true
            }
            sums[key] = entry
        }
        return sums.map { key, value in
            ActivityShare(
                activityID: key.activity, currency: key.currency, spentMinorUnits: value.spent, refundedMinorUnits: value.refunded,
                receivedMinorUnits: value.received, pendingMinorUnits: value.pending, hasUnknown: value.unknown
            )
        }
        .sorted { ($0.activityID, $0.currency) < ($1.activityID, $1.currency) }
    }
}

// MARK: Money that came in beyond what was owed

public enum SurplusTreatment: String, Codable, Hashable, Sendable {
    /// Default: it is income, apart from spending (a separate income category).
    case income
    /// The user's setting: it is not counted anywhere.
    case excluded
}

extension LifeState {
    /// Surplus received beyond what the obligations asked, in `currency`. Never reduces spending. Surplus the user said belongs to another
    /// obligation is not income; everything else (unresolved, gift, other) is, unless the setting excludes it.
    public func surplusIncomeMinorUnits(currency: String, treatment: SurplusTreatment = .income) -> Int64 {
        guard treatment == .income else { return 0 }
        return residuals.values
            .filter { $0.direction == .surplus && $0.amount.currency == currency && $0.classification.value != .otherObligation }
            .reduce(0) { $0 + $1.amount.minorUnits }
    }
}
