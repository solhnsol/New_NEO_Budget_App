import Foundation

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

    /// How far apart a Toss notification and the bank's notification of the same money may be to be linked without asking.
    /// Observed pairs arrive almost together (Hans, 2026-10-23); beyond this and up to `matchToleranceMilliseconds` the
    /// pair is only suggested for review, in case an exception does exist.
    public let tossPairToleranceMilliseconds: Int64

    public init(matchToleranceMilliseconds: Int64 = 600_000, walletTapToleranceMilliseconds: Int64 = 120_000,
                tossPairToleranceMilliseconds: Int64 = 60_000) {
        self.matchToleranceMilliseconds = matchToleranceMilliseconds
        self.walletTapToleranceMilliseconds = walletTapToleranceMilliseconds
        self.tossPairToleranceMilliseconds = tossPairToleranceMilliseconds
    }

    /// Rule id of a bank withdrawal that was read as the Toss purchase it paid (`quickPayRecording`).
    public static let tossQuickPayRuleID = "toss-quick-pay"

    /// How far in time from an incoming notification a stored one can still be a partner or a close. Every rule except the
    /// refund suggestion compares times within one of the tolerances above, so records further away never matter.
    public var searchRadiusMilliseconds: Int64 {
        max(matchToleranceMilliseconds, walletTapToleranceMilliseconds, tossPairToleranceMilliseconds)
    }

    /// The shop (or payee) name with spacing and case removed, which is what a refund is matched to a purchase by. Nil when
    /// there is none.
    public static func purchaseNameKey(_ draft: TransactionCandidateDraft) -> String? { name(draft) }

    /// The `purchaseNameKey` an incoming notification looks for earlier purchases under, or nil when it is not the kind of
    /// notification that is suggested as the return of one (a refund, a cancellation or a deposit with no reference to the
    /// original approval).
    public static func refundSearchKey(for draft: TransactionCandidateDraft) -> String? {
        guard [.refund, .cancellation, .deposit].contains(draft.kind),
              !draft.evidence.contains(where: { $0.kind == .originalApprovalReference }) else { return nil }
        return name(draft)
    }

    public func decide(_ incoming: CorrelationObservation, against records: [CorrelationRecord]) -> CorrelationDecision {
        decide(incoming, nearby: records, sameNamePurchases: records)
    }

    /// The same decision from a part of the records. `nearby` has every record whose time is within
    /// `searchRadiusMilliseconds` of the incoming one, plus the records that corroborate any of them; `sameNamePurchases`
    /// has every purchase record under the incoming notification's `purchaseNameKey` (the only rule that reaches back
    /// further than the tolerances). Records outside both cannot change the decision, so a caller that keeps them indexed
    /// need not hand over the whole history.
    public func decide(
        _ incoming: CorrelationObservation, nearby records: [CorrelationRecord], sameNamePurchases: [CorrelationRecord]
    ) -> CorrelationDecision {
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

        let suggestions = refundSuggestions(for: incoming, in: sameNamePurchases.filter { $0.candidateID != incoming.candidateID }) + sameMoneySuggestions(for: incoming, in: open)
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
        // A person's Toss transfer and the bank's own deposit alert of it: one deposit, whichever alert arrived first.
        if let partner = depositEchoPartner(of: incoming, in: committed, claimedAgainst: records) {
            return CorrelationMatch(candidateID: partner.candidateID, rule: .tossDepositEcho)
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
        // A Toss payment and the bank withdrawal that paid it, the later one recorded as the expense, the earlier one closed.
        let quickPayPartner = quickPayClosed(by: incoming, in: pending)
        if let quickPayPartner { result.append(CorrelationMatch(candidateID: quickPayPartner.candidateID, rule: .tossQuickPay)) }
        // A bank deposit arriving after the Toss alert of the same transfer (which waited for review).
        if Self.isBankDeposit(incoming), let institution = incoming.institution,
           let echo = nearest(pending.filter { record in
               Self.isTossPersonDeposit(record.draft, record.notificationType) && record.institution == institution
                   && pairs(record.draft, incoming.draft, within: tossPairToleranceMilliseconds)
           }, to: incoming) {
            result.append(CorrelationMatch(candidateID: echo.candidateID, rule: .tossDepositEcho))
        }
        // A check card approval arriving after its bank withdrawal (which waited for review).
        if quickPayPartner == nil, incoming.draft.ruleID != Self.tossQuickPayRuleID,
           incoming.draft.kind == .purchase, case let .account(account)? = incoming.binding,
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
        guard let name = Self.refundSearchKey(for: incoming.draft) else { return [] }
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

    // MARK: Toss and the bank report one movement of money

    /// What a notification becomes when it is the second half of a Toss payment paid straight from a bank account.
    /// A Toss payment names no account and a bank withdrawal names no purchase, so neither alone is an expense; together
    /// they are one: the account of the withdrawal, the shop of the Toss payment (`docs/ledger-behavior.md`, Toss pairs).
    public struct QuickPayRecording: Equatable, Sendable {
        /// The draft to assemble: the Toss payment as it is, or the bank's withdrawal read as the purchase it paid.
        public let draft: TransactionCandidateDraft
        /// The account the expense is booked on: the withdrawal's.
        public let binding: ResolvedLedgerBinding
    }

    /// Set only when an unpaired half of a Toss payment is already waiting for review with the same amount within
    /// `tossPairToleranceMilliseconds`, and the bank side's counterparty starts with `토스`. The Toss payment is what proves
    /// that such a withdrawal is a payment and not a transfer to a friend.
    public func quickPayRecording(for incoming: CorrelationObservation, against records: [CorrelationRecord]) -> QuickPayRecording? {
        let pending = records.filter { $0.entryID == nil && $0.corroborates == nil && $0.candidateID != incoming.candidateID }
        if Self.isUnpairedTossPayment(incoming.draft, incoming.notificationType, incoming.binding) {
            guard let withdrawal = nearest(pending.filter {
                Self.isTossNamedWithdrawal($0.draft, $0.binding) && pairs($0.draft, incoming.draft, within: tossPairToleranceMilliseconds)
            }, to: incoming), let binding = withdrawal.binding else { return nil }
            return QuickPayRecording(draft: incoming.draft, binding: binding)
        }
        if Self.isTossNamedWithdrawal(incoming.draft, incoming.binding), let binding = incoming.binding {
            guard let payment = nearest(pending.filter {
                Self.isUnpairedTossPayment($0.draft, $0.notificationType, $0.binding) && pairs($0.draft, incoming.draft, within: tossPairToleranceMilliseconds)
            }, to: incoming), let purchase = Self.purchase(paying: payment.draft, from: incoming.draft) else { return nil }
            return QuickPayRecording(draft: purchase, binding: binding)
        }
        return nil
    }

    /// The earlier half of a Toss payment that the incoming expense (already booked on the withdrawal's account) completes.
    private func quickPayClosed(by incoming: CorrelationObservation, in pending: [CorrelationRecord]) -> CorrelationRecord? {
        guard incoming.draft.kind == .purchase, let binding = incoming.binding else { return nil }
        if incoming.draft.ruleID == Self.tossQuickPayRuleID {
            return nearest(pending.filter {
                Self.isUnpairedTossPayment($0.draft, $0.notificationType, $0.binding) && pairs($0.draft, incoming.draft, within: tossPairToleranceMilliseconds)
            }, to: incoming)
        }
        guard incoming.notificationType == .tossPayment else { return nil }
        return nearest(pending.filter {
            Self.isTossNamedWithdrawal($0.draft, $0.binding) && $0.binding == binding && pairs($0.draft, incoming.draft, within: tossPairToleranceMilliseconds)
        }, to: incoming)
    }

    /// The deposit recorded for the same transfer: the bank's own alert when a Toss alert arrives, or the Toss alert
    /// when the bank's arrives.
    private func depositEchoPartner(of incoming: CorrelationObservation, in committed: [CorrelationRecord],
                                    claimedAgainst records: [CorrelationRecord]) -> CorrelationRecord? {
        guard let institution = incoming.institution else { return nil }
        let isToss = Self.isTossPersonDeposit(incoming.draft, incoming.notificationType)
        guard isToss || Self.isBankDeposit(incoming) else { return nil }
        let partners = committed.filter { record in
            record.recordedAsIncome && record.institution == institution
                && (isToss ? Self.isBankDeposit(record) : Self.isTossPersonDeposit(record.draft, record.notificationType))
                && (incoming.binding == nil || record.binding == incoming.binding)
                && pairs(record.draft, incoming.draft, within: tossPairToleranceMilliseconds)
                && !claimed(record, by: .tossDepositEcho, in: records)
        }
        return nearest(partners, to: incoming)
    }

    /// Same amount and time within `matchToleranceMilliseconds`, but not structurally linked tightly enough to merge:
    /// the review card asks whether it is the same money (invariant 11).
    private func sameMoneySuggestions(for incoming: CorrelationObservation, in records: [CorrelationRecord]) -> [CorrelationMatch] {
        let partners: [CorrelationRecord]
        if Self.isUnpairedTossPayment(incoming.draft, incoming.notificationType, incoming.binding) {
            partners = records.filter { $0.entryID == nil && $0.corroborates == nil && Self.isBankWithdrawal($0.draft, $0.binding) && sameMoney($0, incoming) }
        } else if Self.isBankWithdrawal(incoming.draft, incoming.binding) {
            partners = records.filter {
                $0.entryID == nil && $0.corroborates == nil && Self.isUnpairedTossPayment($0.draft, $0.notificationType, $0.binding) && sameMoney($0, incoming)
            }
        } else if Self.isTossPersonDeposit(incoming.draft, incoming.notificationType), let institution = incoming.institution {
            partners = records.filter {
                $0.entryID != nil && $0.corroborates == nil && $0.recordedAsIncome && Self.isBankDeposit($0) && $0.institution == institution
                    && (incoming.binding == nil || $0.binding == incoming.binding)
                    && sameMoney($0, incoming) && !claimed($0, by: .tossDepositEcho, in: records)
            }
        } else {
            return []
        }
        return partners
            .sorted { lhs, rhs in
                let l = abs(lhs.draft.occurredAt.unixMilliseconds - incoming.draft.occurredAt.unixMilliseconds)
                let r = abs(rhs.draft.occurredAt.unixMilliseconds - incoming.draft.occurredAt.unixMilliseconds)
                return l != r ? l < r : lhs.candidateID.rawValue < rhs.candidateID.rawValue
            }
            .map { CorrelationMatch(candidateID: $0.candidateID, rule: .sameMoneySuggestion) }
    }

    /// Same amount and times no further apart than `tolerance`.
    private func pairs(_ lhs: TransactionCandidateDraft, _ rhs: TransactionCandidateDraft, within tolerance: Int64) -> Bool {
        guard lhs.amount == rhs.amount else { return false }
        let (difference, overflow) = lhs.occurredAt.unixMilliseconds.subtractingReportingOverflow(rhs.occurredAt.unixMilliseconds)
        return !overflow && difference != .min && abs(difference) <= tolerance
    }

    /// A Toss payment that names no account (and no card): the money left some account the message does not say.
    private static func isUnpairedTossPayment(_ draft: TransactionCandidateDraft, _ type: NotificationType?, _ binding: ResolvedLedgerBinding?) -> Bool {
        type == .tossPayment && draft.kind == .purchase && binding == nil && draft.instrument.kind != .creditCard
    }

    /// A bank withdrawal on a registered account whose counterparty begins with `토스` (the parser puts that word in `memoRaw`).
    private static func isTossNamedWithdrawal(_ draft: TransactionCandidateDraft, _ binding: ResolvedLedgerBinding?) -> Bool {
        guard isBankWithdrawal(draft, binding) else { return false }
        return [draft.counterparty.merchantRaw, draft.counterparty.payeeRaw, draft.counterparty.memoRaw].contains { value in
            guard let value else { return false }
            return value.range(of: #"(?<![가-힣A-Za-z0-9])토스(?!뱅크)"#, options: .regularExpression) != nil
        }
    }

    private static func isBankWithdrawal(_ draft: TransactionCandidateDraft, _ binding: ResolvedLedgerBinding?) -> Bool {
        draft.kind == .withdrawal && draft.direction == .outflow && isOnAccount(binding)
    }

    private static func isTossPersonDeposit(_ draft: TransactionCandidateDraft, _ type: NotificationType?) -> Bool {
        type == .tossPersonDeposit && draft.direction == .inflow
    }

    /// A deposit alert from the bank on a registered account (not Toss's own alert of it).
    private static func isBankDeposit(_ observation: CorrelationObservation) -> Bool {
        observation.draft.kind == .deposit && observation.transferCounterpart == nil && observation.notificationType != .tossPersonDeposit
            && isOnAccount(observation.binding)
    }

    private static func isBankDeposit(_ record: CorrelationRecord) -> Bool {
        record.draft.kind == .deposit && record.transferCounterpart == nil && record.notificationType != .tossPersonDeposit
            && isOnAccount(record.binding)
    }

    private static func isOnAccount(_ binding: ResolvedLedgerBinding?) -> Bool {
        if case .account? = binding { return true }
        return false
    }

    /// The bank's withdrawal read as the purchase the Toss payment reported: the shop from Toss, everything else from the bank.
    private static func purchase(paying payment: TransactionCandidateDraft, from withdrawal: TransactionCandidateDraft) -> TransactionCandidateDraft? {
        let shop = payment.counterparty.merchantRaw ?? withdrawal.counterparty.merchantRaw
        return try? TransactionCandidateDraft(
            rawNotificationID: withdrawal.rawNotificationID, eventIndex: withdrawal.eventIndex,
            parserID: withdrawal.parserID, parserVersion: withdrawal.parserVersion, ruleID: tossQuickPayRuleID,
            kind: .purchase, direction: .outflow, amount: withdrawal.amount, balanceAfter: withdrawal.balanceAfter,
            occurredAt: withdrawal.occurredAt, instrument: withdrawal.instrument,
            counterparty: DraftCounterparty(merchantRaw: shop, payeeRaw: nil, memoRaw: withdrawal.counterparty.memoRaw),
            evidence: withdrawal.evidence,
            issues: shop == nil ? withdrawal.issues : withdrawal.issues.filter { $0 != .merchantMissing },
            confidence: withdrawal.confidence
        )
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
    /// What kind of message the provider sent (a Toss payment, a Toss transfer, ...), when the account layer knew.
    public let notificationType: NotificationType?
    /// The institution the notification names, whether or not the account behind it resolved (a Toss transfer names only the bank).
    public let institution: InstitutionID?

    public init(candidateID: TransactionCandidateID, draft: TransactionCandidateDraft, binding: ResolvedLedgerBinding?,
                transferCounterpart: AccountID? = nil, source: String,
                notificationType: NotificationType? = nil, institution: InstitutionID? = nil) {
        self.candidateID = candidateID
        self.draft = draft
        self.binding = binding
        self.transferCounterpart = transferCounterpart
        self.source = source
        self.notificationType = notificationType
        self.institution = institution
    }
}

/// A notification already handled: committed as an entry, waiting for review, or recorded as evidence of another.
public struct CorrelationRecord: Equatable, Sendable {
    public let candidateID: TransactionCandidateID
    public let draft: TransactionCandidateDraft
    public let binding: ResolvedLedgerBinding?
    public let transferCounterpart: AccountID?
    public let source: String
    public let notificationType: NotificationType?
    public let institution: InstitutionID?
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
        notificationType = observation.notificationType
        institution = observation.institution
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
    /// A Toss payment (no account named) and the bank withdrawal that paid it (counterparty `토스...`): one expense.
    case tossQuickPay
    /// A person's Toss transfer and the bank's own deposit alert of it: one deposit.
    case tossDepositEcho
    /// Toss and the bank report the same amount close in time, but too loosely to merge: suggested, never merged.
    case sameMoneySuggestion
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
                  source: evidence?.provider?.rawValue ?? fallbackSource,
                  notificationType: evidence?.type, institution: evidence?.instrument.institution)
    }
}
