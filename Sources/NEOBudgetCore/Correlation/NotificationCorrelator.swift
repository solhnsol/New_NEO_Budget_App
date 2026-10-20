/// Decides, as each notification arrives, whether it is another piece of evidence of a financial act already seen
/// (a check card approval and its bank withdrawal, a pay app and the card it charged, the two legs of a transfer).
///
/// There is no waiting window: a notification is judged against what is already recorded the moment it arrives, and a
/// later partner closes the earlier one. The rules need a **structural** link (both sides resolve to the same registered
/// account or instrument, or one side's counterpart key resolves to the other side's account) on top of the same amount
/// and a nearby time. Amount and time alone only ever produce a suggestion for review (invariant 11). See
/// `docs/correlator-design.md`.
///
/// Pure: no clock, no storage. The caller resolves accounts and counterparts first and applies the decision atomically.
public struct NotificationCorrelator: Sendable {
    /// How far apart two notifications of one act may be. Not a wait: nothing is held back for this long.
    public let matchToleranceMilliseconds: Int64

    /// How far apart a Wallet card payment and the card issuer's own alert of it may be. Observed pairs differ by under
    /// 15 seconds (the Wallet alert second); two minutes keeps a same-amount repeat at one shop a separate payment.
    public let walletTapToleranceMilliseconds: Int64

    public init(matchToleranceMilliseconds: Int64 = 600_000, walletTapToleranceMilliseconds: Int64 = 120_000) {
        self.matchToleranceMilliseconds = matchToleranceMilliseconds
        self.walletTapToleranceMilliseconds = walletTapToleranceMilliseconds
    }

    public func decide(_ incoming: CorrelationObservation, against records: [CorrelationRecord]) -> CorrelationDecision {
        let open = records.filter { $0.candidateID != incoming.candidateID }
        if let match = corroboration(of: incoming, in: open) { return .corroborates(match) }

        let closes = pendingClosed(by: incoming, in: open)
        if let counterpart = incoming.transferCounterpart, isTransferLeg(incoming) {
            let replaced = nearest(open.filter { isIncomeLeg($0, oppositeOf: incoming, counterpart: counterpart) }, to: incoming)
            return .newAct(NewAct(
                transferCounterpart: counterpart,
                closes: closes,
                replacesIncome: replaced.map { CorrelationMatch(candidateID: $0.candidateID, rule: .transferLegs) }
            ))
        }
        if !closes.isEmpty { return .newAct(NewAct(closes: closes)) }

        let suggestions = refundSuggestions(for: incoming, in: open)
        if !suggestions.isEmpty { return .suggests(suggestions) }
        return .newAct(NewAct())
    }

    // MARK: The incoming notification is evidence of an act already recorded

    private func corroboration(of incoming: CorrelationObservation, in records: [CorrelationRecord]) -> CorrelationMatch? {
        let committed = records.filter { $0.entryID != nil && $0.corroborates == nil }
        // A bank withdrawal of a check card payment already recorded from the card's approval.
        if incoming.draft.kind == .withdrawal, case let .account(account)? = incoming.binding {
            let partners = committed.filter { record in
                record.draft.kind == .purchase && record.binding == .account(account) && sameMoney(record, incoming)
                    && !claimed(record, by: .cardWithdrawal, in: records)
            }
            if let partner = nearest(partners, to: incoming) { return CorrelationMatch(candidateID: partner.candidateID, rule: .cardWithdrawal) }
        }
        // A pay app and the card (or account) it charged both report one payment.
        if incoming.draft.kind == .purchase, let binding = incoming.binding {
            let partners = committed.filter { record in
                record.draft.kind == .purchase && record.binding == binding && sameMoney(record, incoming)
                    && record.source != incoming.source
                    && !records.contains { $0.corroborates == record.candidateID && $0.source == incoming.source }
            }
            if let partner = nearest(partners, to: incoming) { return CorrelationMatch(candidateID: partner.candidateID, rule: .sameInstrumentAcrossProviders) }
        }
        // A Wallet card payment (no account of its own) of a payment the card issuer's app already reported.
        if Self.isWalletTap(incoming.draft), let issuer = Self.issuerSource(of: incoming.draft) {
            let partners = committed.filter { record in
                record.draft.kind == .purchase && !Self.isWalletTap(record.draft)
                    && (record.source == issuer || records.contains { $0.corroborates == record.candidateID && $0.source == issuer })
                    && samePayment(record.draft, incoming.draft, tolerance: walletTapToleranceMilliseconds)
                    && !claimed(record, by: .walletTap, in: records)
            }
            if let partner = nearest(partners, to: incoming) { return CorrelationMatch(candidateID: partner.candidateID, rule: .walletTap) }
        }
        // The other leg of a transfer already recorded from its first leg.
        if let binding = incoming.binding, case let .account(account) = binding {
            let partners = committed.filter { record in
                // The recorded leg was committed as a transfer that named this account as its other side.
                guard case let .account(own)? = record.binding, own != account, !record.recordedAsIncome, isTransferLeg(record),
                      record.transferCounterpart == account, record.draft.direction != incoming.draft.direction,
                      sameMoney(record, incoming), !claimed(record, by: .transferLegs, in: records) else { return false }
                return true
            }
            if let partner = nearest(partners, to: incoming) { return CorrelationMatch(candidateID: partner.candidateID, rule: .transferLegs) }
        }
        return nil
    }

    // MARK: The incoming notification closes earlier ones that were waiting for it

    private func pendingClosed(by incoming: CorrelationObservation, in records: [CorrelationRecord]) -> [CorrelationMatch] {
        let pending = records.filter { $0.entryID == nil && $0.corroborates == nil }
        var result: [CorrelationMatch] = []
        // A check card approval arriving after its bank withdrawal (which waited for review).
        if incoming.draft.kind == .purchase, case let .account(account)? = incoming.binding,
           let withdrawal = nearest(pending.filter { $0.draft.kind == .withdrawal && $0.binding == .account(account) && sameMoney($0, incoming) }, to: incoming) {
            result.append(CorrelationMatch(candidateID: withdrawal.candidateID, rule: .cardWithdrawal))
        }
        // The issuer's own alert arriving after the Wallet payment of it, which waited because Wallet names no account.
        if incoming.draft.kind == .purchase, incoming.binding != nil,
           let tap = nearest(pending.filter { record in
               Self.isWalletTap(record.draft) && Self.issuerSource(of: record.draft) == incoming.source
                   && samePayment(record.draft, incoming.draft, tolerance: walletTapToleranceMilliseconds)
           }, to: incoming) {
            result.append(CorrelationMatch(candidateID: tap.candidateID, rule: .walletTap))
        }
        // A transfer leg naming the account of a withdrawal that waited for review (a Kakao Pay charge after the bank's withdrawal).
        if let counterpart = incoming.transferCounterpart, isTransferLeg(incoming),
           let withdrawal = nearest(pending.filter {
               $0.binding == .account(counterpart) && $0.draft.direction != incoming.draft.direction && sameMoney($0, incoming)
           }, to: incoming) {
            result.append(CorrelationMatch(candidateID: withdrawal.candidateID, rule: .transferLegs))
        }
        return result
    }

    // MARK: Amount and time only: a suggestion, never a merge

    private func refundSuggestions(for incoming: CorrelationObservation, in records: [CorrelationRecord]) -> [CorrelationMatch] {
        guard [.refund, .cancellation, .deposit].contains(incoming.draft.kind),
              !incoming.draft.evidence.contains(where: { $0.kind == .originalApprovalReference }),
              let name = Self.name(incoming.draft) else { return [] }
        return records
            .filter { record in
                record.entryID != nil && record.corroborates == nil && record.draft.kind == .purchase && Self.name(record.draft) == name
                    && record.draft.amount.currency == incoming.draft.amount.currency
                    && record.draft.amount.minorUnits >= incoming.draft.amount.minorUnits
                    && record.draft.occurredAt.unixMilliseconds <= incoming.draft.occurredAt.unixMilliseconds
            }
            .sorted { ($0.draft.occurredAt.unixMilliseconds, $0.candidateID.rawValue) > ($1.draft.occurredAt.unixMilliseconds, $1.candidateID.rawValue) }
            .map { CorrelationMatch(candidateID: $0.candidateID, rule: .refundSuggestion) }
    }

    // MARK: Helpers

    private func isTransferLeg(_ observation: CorrelationObservation) -> Bool {
        [.transferOut, .transferIn, .withdrawal, .deposit, .walletTopUp, .cashWithdrawal].contains(observation.draft.kind)
    }

    private func isTransferLeg(_ record: CorrelationRecord) -> Bool {
        [.transferOut, .transferIn, .withdrawal, .deposit, .walletTopUp, .cashWithdrawal].contains(record.draft.kind)
    }

    /// A deposit on the transfer's other account that was recorded as income before this leg arrived.
    private func isIncomeLeg(_ record: CorrelationRecord, oppositeOf incoming: CorrelationObservation, counterpart: AccountID) -> Bool {
        record.entryID != nil && record.corroborates == nil && record.recordedAsIncome && record.binding == .account(counterpart)
            && record.draft.direction != incoming.draft.direction && sameMoney(record, incoming)
    }

    private func claimed(_ record: CorrelationRecord, by rule: CorrelationRule, in records: [CorrelationRecord]) -> Bool {
        records.contains { $0.corroborates == record.candidateID && $0.corroborationRule == rule }
    }

    /// Same amount, a merchant name one of which contains the other, and close in time.
    private func samePayment(_ lhs: TransactionCandidateDraft, _ rhs: TransactionCandidateDraft, tolerance: Int64) -> Bool {
        guard lhs.amount == rhs.amount else { return false }
        let (difference, overflow) = lhs.occurredAt.unixMilliseconds.subtractingReportingOverflow(rhs.occurredAt.unixMilliseconds)
        guard !overflow, difference != .min, abs(difference) <= tolerance else { return false }
        guard let left = Self.shopKey(lhs), let right = Self.shopKey(rhs) else { return false }
        return left.contains(right) || right.contains(left)
    }

    private static func isWalletTap(_ draft: TransactionCandidateDraft) -> Bool {
        draft.ruleID == KoreanFinancialNotificationParser.walletCardPaymentRuleID
    }

    /// The provider whose own app reports the card named in a Wallet payment.
    private static func issuerSource(of tap: TransactionCandidateDraft) -> String? {
        tap.instrument.displayNameRaw?.contains("현대카드") == true ? ProviderCatalog.hyundaiCard.rawValue : nil
    }

    /// Letters and digits only, so `코페이_2 - 스카이락 볼링장` and `스카이락볼링장` compare as one shop; too short a name never matches.
    private static func shopKey(_ draft: TransactionCandidateDraft) -> String? {
        guard let raw = draft.counterparty.merchantRaw else { return nil }
        let key = String(NotificationText.normalize(raw).lowercased().filter { $0.isLetter || $0.isNumber })
        return key.count >= 2 ? key : nil
    }

    private func sameMoney(_ record: CorrelationRecord, _ incoming: CorrelationObservation) -> Bool {
        guard record.draft.amount == incoming.draft.amount else { return false }
        let (difference, overflow) = record.draft.occurredAt.unixMilliseconds.subtractingReportingOverflow(incoming.draft.occurredAt.unixMilliseconds)
        return !overflow && difference != .min && abs(difference) <= matchToleranceMilliseconds
    }

    /// The partner closest in time; ties go to the smaller candidate ID, so the choice never depends on arrival order.
    private func nearest(_ records: [CorrelationRecord], to incoming: CorrelationObservation) -> CorrelationRecord? {
        let time = incoming.draft.occurredAt.unixMilliseconds
        return records.min { lhs, rhs in
            let l = abs(lhs.draft.occurredAt.unixMilliseconds - time), r = abs(rhs.draft.occurredAt.unixMilliseconds - time)
            return l != r ? l < r : lhs.candidateID.rawValue < rhs.candidateID.rawValue
        }
    }

    private static func name(_ draft: TransactionCandidateDraft) -> String? {
        let raw = draft.counterparty.merchantRaw ?? draft.counterparty.payeeRaw
        let key = raw.map { NotificationText.normalize($0).lowercased().filter { !$0.isWhitespace } }
        return key?.isEmpty == false ? key : nil
    }
}

/// A notification that just arrived, with its account already resolved.
public struct CorrelationObservation: Codable, Equatable, Sendable {
    public let candidateID: TransactionCandidateID
    public let draft: TransactionCandidateDraft
    /// Where the money moved, when the account layer resolved it.
    public let binding: ResolvedLedgerBinding?
    /// The other side, only when its key resolves to one of the user's registered accounts.
    public let transferCounterpart: AccountID?
    /// Who delivered it (app or provider), to tell two apps reporting one payment from one app reporting two.
    public let source: String

    public init(candidateID: TransactionCandidateID, draft: TransactionCandidateDraft, binding: ResolvedLedgerBinding?,
                transferCounterpart: AccountID? = nil, source: String) {
        self.candidateID = candidateID
        self.draft = draft
        self.binding = binding
        self.transferCounterpart = transferCounterpart
        self.source = source
    }
}

/// A notification already handled: committed as an entry, waiting for review, or recorded as evidence of another.
public struct CorrelationRecord: Equatable, Sendable {
    public let candidateID: TransactionCandidateID
    public let draft: TransactionCandidateDraft
    public let binding: ResolvedLedgerBinding?
    public let transferCounterpart: AccountID?
    public let source: String
    /// The entry it was committed as; nil while it waits for review or when it only corroborates another.
    public let entryID: LedgerEntryID?
    /// Committed as income (a deposit no transfer leg had claimed yet).
    public let recordedAsIncome: Bool
    /// The candidate whose act this one is evidence of, and by which rule.
    public let corroborates: TransactionCandidateID?
    public let corroborationRule: CorrelationRule?

    public init(observation: CorrelationObservation, entryID: LedgerEntryID? = nil, recordedAsIncome: Bool = false,
                corroborates: CorrelationMatch? = nil) {
        candidateID = observation.candidateID
        draft = observation.draft
        binding = observation.binding
        transferCounterpart = observation.transferCounterpart
        source = observation.source
        self.entryID = entryID
        self.recordedAsIncome = recordedAsIncome
        self.corroborates = corroborates?.candidateID
        corroborationRule = corroborates?.rule
    }
}

public enum CorrelationRule: String, Codable, Sendable {
    /// A check card approval and the bank withdrawal of the same account.
    case cardWithdrawal
    /// Two apps (a pay app and a card issuer) reporting one payment on the same instrument.
    case sameInstrumentAcrossProviders
    /// The two legs of a transfer between the user's own accounts.
    case transferLegs
    /// A Wallet card payment and the card issuer's own alert of the same payment (Wallet names no account; the issuer's app does).
    case walletTap
    /// A refund without an original reference and a recent purchase of the same name: suggested, never merged.
    case refundSuggestion
}

public struct CorrelationMatch: Codable, Hashable, Sendable {
    public let candidateID: TransactionCandidateID
    public let rule: CorrelationRule

    public init(candidateID: TransactionCandidateID, rule: CorrelationRule) {
        self.candidateID = candidateID
        self.rule = rule
    }
}

public struct NewAct: Equatable, Sendable {
    /// Assemble a transfer to this account (one leg is enough when the other side is a registered account).
    public let transferCounterpart: AccountID?
    /// Earlier notifications waiting for review that become evidence of this act.
    public let closes: [CorrelationMatch]
    /// The other leg of this transfer, already committed as income: it must be corrected into this transfer.
    public let replacesIncome: CorrelationMatch?

    public init(transferCounterpart: AccountID? = nil, closes: [CorrelationMatch] = [], replacesIncome: CorrelationMatch? = nil) {
        self.transferCounterpart = transferCounterpart
        self.closes = closes
        self.replacesIncome = replacesIncome
    }
}

public enum CorrelationDecision: Equatable, Sendable {
    /// Evidence of an act already recorded: no new entry.
    case corroborates(CorrelationMatch)
    /// A new act, possibly closing earlier notifications that waited for it.
    case newAct(NewAct)
    /// Amount and time only: review, with these as the likely partners.
    case suggests([CorrelationMatch])
}

extension CorrelationObservation {
    /// What the account layer knows of a notification: where the money moved (`resolve`), and the other side only
    /// when its key is one of the user's registered accounts (`resolveCounterpart`; someone else's account stays nil).
    /// A credit card counterpart is not a transfer and is left out.
    public init(candidateID: TransactionCandidateID, draft: TransactionCandidateDraft, evidence: AccountEvidence?,
                registry: AccountRegistry, fallbackSource: String) {
        var binding: ResolvedLedgerBinding?
        var counterpart: AccountID?
        if let evidence {
            if case let .resolved(resolved, _) = registry.resolve(evidence) { binding = resolved }
            if case let .resolved(.account(account), _)? = registry.resolveCounterpart(evidence), binding != .account(account) {
                counterpart = account
            }
        }
        self.init(candidateID: candidateID, draft: draft, binding: binding, transferCounterpart: counterpart,
                  source: evidence?.provider?.rawValue ?? fallbackSource)
    }
}
