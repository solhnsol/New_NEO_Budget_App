import Foundation
import Testing
@testable import NEOBudgetCore

/// Fixtures are synthetic. They reproduce the message shapes and the failure cases found in real notifications:
/// a check card read as a credit card, a hub app read as a bank account, one account reached through two apps.
@Suite struct AccountResolutionTests {
    private let extractor = AccountEvidenceExtractor()
    private let account = { (id: String) in ResolvedLedgerBinding.account(AccountID(rawValue: id)) }
    private let card = { (id: String) in ResolvedLedgerBinding.creditInstrument(CreditInstrumentID(rawValue: id)) }

    private func note(_ app: String, title: String = "", subtitle: String = "", body: String, id: String = "n1") -> RawNotification {
        RawNotification(id: id, source: NotificationSource(applicationIdentifier: "x.\(id)", displayName: app),
                        capturedAtUnixMilliseconds: 1_000, title: title, subtitle: subtitle, body: body)
    }

    private func hyundai(_ product: String, id: String = "h") -> RawNotification {
        note("현대카드", body: "김가명 님, 현대 \(product) 승인 \r\n51,000원 일시불, 10/02 19:13 \r\n가맹점A", id: id)
    }

    private func woori(_ number: String, app: String = "우리WON뱅킹", id: String = "w") -> RawNotification {
        note(app, body: "[Web발신]\n우리 출금 51,000원 \(number) 잔액 1,234,000원 10/02 19:13:20", id: id)
    }

    private let wooriA2 = MaskedNumber("1002-123-456***")!
    private let wooriA7 = MaskedNumber("1002-999-111***")!

    /// A2 = a Woori account, also what the check card settles on. A7 = a second Woori account. C8 = the credit card.
    private func registry() throws -> AccountRegistry {
        var registry = AccountRegistry()
        try registry.adopt(account("A2"), displayName: "생활비", institution: .woori, keys: [
            InstrumentKey(institution: .woori, identifier: .accountNumber(wooriA2)),
            InstrumentKey(institution: .hyundaiCard, identifier: .cardProduct("체크"))
        ])
        try registry.adopt(account("A7"), displayName: "저축", institution: .woori, keys: [
            InstrumentKey(institution: .woori, identifier: .accountNumber(wooriA7))
        ])
        try registry.adopt(card("C8"), displayName: "현대 MM", institution: .hyundaiCard, keys: [
            InstrumentKey(institution: .hyundaiCard, identifier: .cardProduct("MM"))
        ])
        return registry
    }

    private func resolved(_ decision: AccountResolutionDecision) -> ResolvedLedgerBinding? {
        if case let .resolved(binding, _) = decision { return binding }
        return nil
    }

    // MARK: Source, type and instrument are separate

    @Test func providerAliasesCoverDeviceLanguageAndBrandNames() {
        func provider(_ name: String) -> SourceProviderID? {
            ProviderCatalog.standard.provider(for: NotificationSource(applicationIdentifier: "x", displayName: name))
        }
        #expect(provider("Wallet") == ProviderCatalog.wallet && provider("지갑") == ProviderCatalog.wallet)
        #expect(provider("Toss") == ProviderCatalog.toss && provider("토스") == ProviderCatalog.toss)
        #expect(provider("Kakaopay") == ProviderCatalog.kakaoPay && provider("카카오페이") == ProviderCatalog.kakaoPay)
        #expect(provider("우리WON뱅킹") == ProviderCatalog.woori && provider("우리은행") == ProviderCatalog.woori)
        #expect(provider("현대카드") == ProviderCatalog.hyundaiCard)
        #expect(provider("토스뱅크") == SourceProviderID(rawValue: "tossbank"))
        #expect(provider("Unknown App") == nil)
    }

    @Test func noBundleIdentifierIsNeeded() {
        let source = NotificationSource(applicationIdentifier: "", displayName: "Toss")
        #expect(ProviderCatalog.standard.provider(for: source) == ProviderCatalog.toss)
    }

    // MARK: Hyundai Card

    @Test func hyundaiProductIsReadAndDecidesTheKind() {
        let credit = extractor.evidence(from: hyundai("MM"))
        let check = extractor.evidence(from: hyundai("체크"))
        #expect(credit.type == .cardApproval && credit.instrument.kind == .creditCard)
        #expect(credit.instrument.identifier == .cardProduct("MM"))
        #expect(check.instrument.kind == .debitCard && check.instrument.identifier == .cardProduct("체크"))
        #expect(check.instrument.institution == .hyundaiCard)
    }

    @Test func unlistedProductKeepsItsNameButNeverBinds() throws {
        let evidence = extractor.evidence(from: hyundai("ZERO"))
        #expect(evidence.instrument.kind == .unknown)
        #expect(try registry().resolve(evidence) == .needsConfirmation(.instrumentKindUnknown, suggestion: nil))
    }

    /// Real failure: a check-card purchase was read as the credit card and booked to the card liability.
    @Test func checkCardApprovalIsNotBookedToTheCreditCard() throws {
        var registry = try registry()
        let check = extractor.evidence(from: hyundai("체크"))
        let credit = extractor.evidence(from: hyundai("MM"))
        #expect(resolved(registry.resolve(check)) == account("A2"))
        #expect(resolved(registry.resolve(credit)) == card("C8"))

        // Even a rule written for the credit card cannot capture a check card: the key matches first, and a
        // check card never fits a card liability.
        try registry.addSourceRule(id: SourceRuleID(rawValue: "r"), provider: ProviderCatalog.hyundaiCard, types: [.cardApproval],
                                   institution: .hyundaiCard, kind: .creditCard, binding: card("C8"), createdAtUnixMilliseconds: 1)
        #expect(resolved(registry.resolve(check)) == account("A2"))
    }

    @Test func checkCardWithoutAKnownKeyBecomesACandidateNotACardPurchase() {
        var registry = AccountRegistry()
        let decision = registry.observe(extractor.evidence(from: hyundai("체크")), notificationID: "h", capturedAtUnixMilliseconds: 1)
        guard case let .newCandidate(id) = decision else { Issue.record("expected candidate"); return }
        #expect(registry.candidate(id)?.kind == .debitCard)
        #expect(throws: AccountRegistryError.kindMismatch) {
            try registry.confirmAsNew(id, displayName: "x", kind: .creditInstrument(currency: "KRW"), makeID: { "c" })
        }
    }

    @Test func aCheckCardCannotBeLinkedToACardLiability() throws {
        var registry = AccountRegistry()
        try registry.adopt(card("C8"), displayName: "현대 MM", institution: .hyundaiCard)
        let decision = registry.observe(extractor.evidence(from: hyundai("체크")), notificationID: "h", capturedAtUnixMilliseconds: 1)
        guard case let .newCandidate(id) = decision else { Issue.record("expected candidate"); return }
        #expect(throws: AccountRegistryError.kindMismatch) { try registry.link(id, to: card("C8")) }
    }

    @Test func productIsAClueNotAGlobalIdentifier() throws {
        var registry = try registry()
        // The same product name at another issuer is a different key.
        let other = AccountEvidence(provider: nil, type: .cardApproval,
                                    instrument: FinancialInstrumentHint(institution: InstitutionID(rawValue: "otherissuer"), kind: .creditCard,
                                                                         identifier: .cardProduct("MM")))
        guard case .newCandidate = registry.resolve(other) else { Issue.record("must not match across issuers"); return }
        // Two accounts can't both claim one product: the second card of a product needs a last-four key.
        #expect(throws: (any Error).self) {
            try registry.adopt(card("C9"), displayName: "또 하나", institution: .hyundaiCard,
                               keys: [InstrumentKey(institution: .hyundaiCard, identifier: .cardProduct("MM"))])
        }
    }

    // MARK: Woori

    @Test func wooriNumberAndBalanceAreExtractedFromBothAppNames() {
        let a = extractor.evidence(from: woori("1002-123-456***", app: "우리WON뱅킹"))
        let b = extractor.evidence(from: woori("1002-123-456***", app: "우리은행"))
        #expect(a.type == .bankTransaction && a.instrument.identifier == .accountNumber(wooriA2))
        #expect(a.balanceMinorUnits == 1_234_000)
        #expect(a.instrument == b.instrument)
    }

    @Test func twoWooriAccountsNeverCrossLink() throws {
        let registry = try registry()
        #expect(resolved(registry.resolve(extractor.evidence(from: woori("1002-123-456***")))) == account("A2"))
        #expect(resolved(registry.resolve(extractor.evidence(from: woori("1002-999-111***")))) == account("A7"))
        guard case .newCandidate = registry.resolve(extractor.evidence(from: woori("1002-555-777***"))) else {
            Issue.record("a third number is a new candidate"); return
        }
    }

    @Test func lookAlikeNumbersAreNotAccountNumbers() {
        for body in ["결제 99,000원 2026-10-09 12:00", "문의 010-1234-5678", "승인 12,345,678원"] {
            #expect(extractor.evidence(from: note("우리WON뱅킹", body: body)).type == .unrecognized)
        }
    }

    // MARK: Toss: a hub, not an account

    private func tossPayment(_ method: String) -> RawNotification {
        note("Toss", title: "15,600원 결제", body: "가맹점A (\(method)) | 일시불")
    }

    private var tossPersonDeposit: RawNotification {
        note("Toss", title: "송금", body: "김가명님이 28,500원을 우리 계좌로 입금했어요.")
    }

    private var tossBankTransfer: RawNotification {
        note("Toss", title: "260,000원 입금", body: "김가명 → 내 토스뱅크 통장 (토스뱅크 1000)")
    }

    @Test func tossMessagesNameDifferentInstrumentsByType() {
        let payment = extractor.evidence(from: tossPayment("현대카드MM"))
        #expect(payment.type == .tossPayment && payment.instrument.institution == .hyundaiCard)
        #expect(payment.instrument.kind == .creditCard && payment.instrument.identifier == .cardProduct("MM"))
        let deposit = extractor.evidence(from: tossPersonDeposit)
        #expect(deposit.type == .tossPersonDeposit && deposit.instrument.institution == .woori && deposit.instrument.identifier == nil)
        let transfer = extractor.evidence(from: tossBankTransfer)
        #expect(transfer.type == .tossBankTransfer && transfer.instrument.institution == .tossBank)
        let account = extractor.evidence(from: note("Toss", title: "9,999원 결제 ", body: "우리은행 ・ 가맹점A\n결제했어요."))
        #expect(account.instrument.institution == .woori && account.instrument.kind == .bankAccount)
    }

    @Test func aTossPaymentByCardResolvesToTheSameCardAsTheCardAppMessage() throws {
        let registry = try registry()
        #expect(resolved(registry.resolve(extractor.evidence(from: tossPayment("현대카드MM")))) == card("C8"))
        #expect(resolved(registry.resolve(extractor.evidence(from: hyundai("MM")))) == card("C8"))
    }

    /// Real failure: a rule "Toss -> the Toss Bank account" absorbed deposits that landed in Woori accounts.
    @Test func tossPersonDepositNeverFallsToTheTossBankAccount() throws {
        var registry = try registry()
        try registry.adopt(account("TB"), displayName: "토스뱅크", institution: .tossBank)
        try registry.addSourceRule(id: SourceRuleID(rawValue: "tb"), provider: ProviderCatalog.toss,
                                   types: [.tossBankTransfer, .tossBankInterest], institution: .tossBank, kind: .bankAccount,
                                   binding: account("TB"), createdAtUnixMilliseconds: 1)
        // The Toss Bank messages resolve through the rule...
        #expect(resolved(registry.resolve(extractor.evidence(from: tossBankTransfer))) == account("TB"))
        // ...the person's deposit does not: it names Woori, and Woori has two accounts.
        let decision = registry.resolve(extractor.evidence(from: tossPersonDeposit))
        #expect(decision == .needsConfirmation(.noIdentifier, suggestion: nil))
    }

    @Test func aRuleForOneTossMessageTypeDoesNotApplyToAnother() throws {
        var registry = AccountRegistry()
        try registry.adopt(account("TB"), displayName: "토스뱅크", institution: .tossBank)
        try registry.addSourceRule(id: SourceRuleID(rawValue: "tb"), provider: ProviderCatalog.toss, types: [.tossBankTransfer],
                                   institution: .tossBank, kind: .bankAccount, binding: account("TB"), createdAtUnixMilliseconds: 1)
        let interest = extractor.evidence(from: note("Toss", title: "이자 받았어요", body: "토스뱅크 통장에 이자 1원 (토스뱅크 1000)"))
        #expect(interest.type == .tossBankInterest)
        #expect(registry.resolve(interest) == .needsConfirmation(.noIdentifier, suggestion: nil))
    }

    @Test func unknownTossPaymentMethodIsNotGuessed() throws {
        let decision = try registry().resolve(extractor.evidence(from: note("Toss", title: "5,000원 결제", body: "가맹점A | 일시불")))
        #expect(decision == .needsConfirmation(.institutionUnknown, suggestion: nil))
    }

    // MARK: Kakao Pay

    private var kakaoCharge: RawNotification { note("Kakaopay", title: "10,000원 충전했어요", body: "- 충전계좌 : 우리 4321") }
    private var kakaoSend: RawNotification {
        note("Kakaopay", title: "송금했어요", body: "송금했어요\n토스뱅크 8765 (홍*동)계좌로 5,000원을 송금했어요.\n메모 : 점심")
    }

    @Test func kakaoNamesTheOtherBankAndItsLastDigits() {
        let charge = extractor.evidence(from: kakaoCharge)
        #expect(charge.type == .kakaoCharge && charge.instrument.kind == .prepaidWallet && charge.instrument.institution == .kakaoPay)
        #expect(charge.counterpart?.institution == .woori && charge.counterpart?.identifier == .accountTail("4321"))
        let send = extractor.evidence(from: kakaoSend)
        #expect(send.type == .kakaoSend && send.counterpart?.institution == .tossBank && send.counterpart?.identifier == .accountTail("8765"))
    }

    @Test func counterpartNeedsALinkedKeyAndNeverCreatesACandidate() throws {
        var registry = try registry()
        let send = extractor.evidence(from: kakaoSend)
        #expect(registry.resolveCounterpart(send) == .needsConfirmation(.counterpartNotRegistered, suggestion: nil))
        _ = registry.observe(send, notificationID: "k", capturedAtUnixMilliseconds: 1)
        #expect(registry.candidates.isEmpty, "the recipient is often someone else's account")

        try registry.addKey(InstrumentKey(institution: .woori, identifier: .accountTail("4321")), to: account("A2"))
        let charge = extractor.evidence(from: kakaoCharge)
        #expect(resolved(registry.resolveCounterpart(charge)!) == account("A2"))
    }

    @Test func kakaoWalletBindsOnlyThroughAnExplicitRuleOverItsMessageTypes() throws {
        var registry = try registry()
        try registry.adopt(account("KW"), displayName: "카카오페이머니", institution: .kakaoPay)
        let send = extractor.evidence(from: kakaoSend)
        #expect(registry.resolve(send) == .needsConfirmation(.noIdentifier, suggestion: nil))
        try registry.addSourceRule(id: SourceRuleID(rawValue: "kw"), provider: ProviderCatalog.kakaoPay,
                                   types: [.kakaoSend, .kakaoCharge, .kakaoReceive], institution: .kakaoPay,
                                   kind: .prepaidWallet, binding: account("KW"), createdAtUnixMilliseconds: 1)
        #expect(resolved(registry.resolve(send)) == account("KW"))
        #expect(resolved(registry.resolve(extractor.evidence(from: kakaoCharge))) == account("KW"))
    }

    // MARK: Wallet transit card

    @Test func transitFareAndBalanceAreReadFromSubtitleAndBody() {
        let fare = extractor.evidence(from: note("Wallet", title: "Seoul Transit", subtitle: "₩1,550 for Metro", body: "Your new balance is ₩10,000."))
        #expect(fare.type == .transitFare && fare.textAmountMinorUnits == 1_550 && fare.balanceMinorUnits == 10_000)
        let none = extractor.evidence(from: note("Wallet", title: "Seoul Transit", subtitle: "Trip in Progress",
                                                  body: "There was no charge for this transaction.\nYour current balance is ₩10,000."))
        #expect(none.type == .transitNoCharge && none.textAmountMinorUnits == nil)
        let only = extractor.evidence(from: note("Wallet", title: "Seoul Transit", subtitle: "Metro Card Read", body: "Your current balance is ₩8,450."))
        #expect(only.type == .transitBalanceOnly && only.balanceMinorUnits == 8_450)
    }

    @Test func aWalletCardTapIsSupplementaryAndNeverResolves() throws {
        let tap = extractor.evidence(from: note("Wallet", title: "현대카드", subtitle: "가맹점A, 서울", body: "₩5,300"))
        #expect(tap.type == .walletCardTap)
        #expect(try registry().resolve(tap) == .needsConfirmation(.supplementaryNotification, suggestion: nil))
    }

    @Test func transitRuleIsExclusiveToItsMessageTypes() throws {
        var registry = AccountRegistry()
        try registry.adopt(account("T"), displayName: "교통카드", institution: .transit)
        try registry.addSourceRule(id: SourceRuleID(rawValue: "t"), provider: ProviderCatalog.wallet, types: [.transitFare],
                                   institution: .transit, kind: .transitCard, binding: account("T"), createdAtUnixMilliseconds: 1)
        let fare = extractor.evidence(from: note("Wallet", subtitle: "₩1,550 for Metro", body: "Your new balance is ₩10,000."))
        let balanceOnly = extractor.evidence(from: note("Wallet", subtitle: "Metro Card Read", body: "Your current balance is ₩8,450."))
        #expect(resolved(registry.resolve(fare)) == account("T"))
        #expect(registry.resolve(balanceOnly) == .needsConfirmation(.noIdentifier, suggestion: nil))
    }

    // MARK: Rules and siblings

    @Test func ruleStopsApplyingWhenAnotherAccountCouldHaveProducedTheMessage() throws {
        var registry = AccountRegistry()
        try registry.adopt(card("C1"), displayName: "카드1", institution: .hyundaiCard)
        let unlisted = AccountEvidence(provider: ProviderCatalog.hyundaiCard, type: .cardApproval,
                                       instrument: FinancialInstrumentHint(institution: .hyundaiCard, kind: .creditCard))
        try registry.addSourceRule(id: SourceRuleID(rawValue: "r"), provider: ProviderCatalog.hyundaiCard, types: [.cardApproval],
                                   institution: .hyundaiCard, kind: .creditCard, binding: card("C1"), createdAtUnixMilliseconds: 1)
        #expect(resolved(registry.resolve(unlisted)) == card("C1"))
        try registry.adopt(card("C2"), displayName: "카드2", institution: .hyundaiCard)
        #expect(registry.resolve(unlisted) == .needsConfirmation(.sourceRuleHasSiblingAccounts, suggestion: card("C1")))
    }

    @Test func ruleCreationNeedsAcknowledgementWhenSiblingsExist() throws {
        var registry = try registry()
        #expect(throws: AccountRegistryError.siblingsExist([account("A7")])) {
            try registry.addSourceRule(id: SourceRuleID(rawValue: "r"), provider: ProviderCatalog.toss, types: [.tossPersonDeposit],
                                       institution: .woori, kind: .bankAccount, binding: account("A2"), createdAtUnixMilliseconds: 1)
        }
        try registry.addSourceRule(id: SourceRuleID(rawValue: "r"), provider: ProviderCatalog.toss, types: [.tossPersonDeposit],
                                   institution: .woori, kind: .bankAccount, binding: account("A2"),
                                   acknowledgingSiblings: true, createdAtUnixMilliseconds: 1)
        // Acknowledged, but still only a suggestion while Woori has a second account.
        #expect(registry.resolve(extractor.evidence(from: tossPersonDeposit))
                == .needsConfirmation(.sourceRuleHasSiblingAccounts, suggestion: account("A2")))
    }

    // MARK: Candidates and manual accounts

    @Test func newKeyBecomesACandidateOncePerNotificationAndIsLinkedAcrossInstitutions() throws {
        var registry = try registry()
        let evidence = extractor.evidence(from: woori("1002-555-777***"))
        let decision = registry.observe(evidence, notificationID: "n1", capturedAtUnixMilliseconds: 100)
        _ = registry.observe(evidence, notificationID: "n1", capturedAtUnixMilliseconds: 100)
        _ = registry.observe(evidence, notificationID: "n2", capturedAtUnixMilliseconds: 50)
        guard case let .newCandidate(id) = decision, let candidate = registry.candidate(id) else { Issue.record("no candidate"); return }
        #expect(candidate.occurrenceCount == 2 && candidate.evidenceNotificationIDs == ["n1", "n2"])
        try registry.link(id, to: account("A7"))
        #expect(resolved(registry.resolve(evidence)) == account("A7"))
        #expect(registry.profile(account("A7"))?.keys.count == 2)
    }

    @Test func confirmingAsNewCreatesATargetWithAnInternalID() throws {
        var registry = AccountRegistry()
        let evidence = extractor.evidence(from: woori("1002-123-456***"))
        guard case let .newCandidate(id) = registry.observe(evidence, notificationID: "n1", capturedAtUnixMilliseconds: 1) else {
            Issue.record("expected candidate"); return
        }
        let opening = try Money(minorUnits: 0, currency: "KRW")
        let target = try registry.confirmAsNew(id, displayName: " 월급 통장 ", kind: .account(.bank, openingBalance: opening), makeID: { "acc-001" })
        #expect(target.binding == account("acc-001"))
        #expect(registry.profile(target.binding)?.displayName == "월급 통장")
        #expect(resolved(registry.resolve(evidence)) == account("acc-001"))
        try registry.rename(target.binding, to: "비상금")
        #expect(resolved(registry.resolve(evidence)) == account("acc-001"))
    }

    @Test func userCanAddAnAccountByHand() throws {
        var registry = AccountRegistry()
        let opening = try Money(minorUnits: 0, currency: "KRW")
        let target = try registry.addAccount(displayName: "비상금", institution: .woori, kind: .account(.bank, openingBalance: opening), makeID: { "a9" })
        let evidence = extractor.evidence(from: woori("1002-123-456***"))
        guard case .newCandidate = registry.resolve(evidence) else { Issue.record("no key yet"); return }
        try registry.addKey(InstrumentKey(institution: .woori, identifier: .accountNumber(wooriA2)), to: target.binding)
        #expect(resolved(registry.resolve(evidence)) == target.binding)
    }

    @Test func unrecognizedAndUnknownProviderNeverResolve() throws {
        let registry = try registry()
        let unknownApp = extractor.evidence(from: note("Mystery", body: "출금 1,000원 1002-123-456***"))
        #expect(unknownApp.type == .unrecognized)
        #expect(registry.resolve(unknownApp) == .needsConfirmation(.unrecognizedNotificationType, suggestion: nil))
    }

    // MARK: Adapter and persistence

    @Test func adapterNeverReportsAConfirmationAsResolved() throws {
        let registry = try registry()
        let known = extractor.evidence(from: woori("1002-123-456***", id: "k"))
        let unknown = extractor.evidence(from: woori("1002-555-777***", id: "u"))
        let resolver = RegistryAccountResolver(registry: registry) { ["k": known, "u": unknown][$0] }
        func draft(_ id: String) throws -> TransactionCandidateDraft {
            try TransactionCandidateDraft(rawNotificationID: id, parserID: "p", parserVersion: "1", ruleID: "r",
                                          kind: .withdrawal, direction: .outflow, amount: Money(minorUnits: 1, currency: "KRW"),
                                          occurredAt: ObservedTimestamp(unixMilliseconds: 1, precision: .second, source: .text),
                                          confidence: .high)
        }
        #expect(try resolver.resolve(draft("k")) == .resolved(account("A2")))
        #expect(try resolver.resolve(draft("u")) == .unresolved(.unknownAccount))
        #expect(try resolver.resolve(draft("zzz")) == .unresolved(.unboundSource))
    }

    @Test func registryRoundTripsThroughCodable() throws {
        var registry = try registry()
        _ = registry.observe(extractor.evidence(from: woori("1002-555-777***")), notificationID: "n", capturedAtUnixMilliseconds: 1)
        try registry.addSourceRule(id: SourceRuleID(rawValue: "t"), provider: ProviderCatalog.wallet, types: [.transitFare],
                                   institution: .transit, kind: .transitCard, binding: account("A7"), acknowledgingSiblings: true,
                                   createdAtUnixMilliseconds: 1)
        let data = try JSONEncoder().encode(registry)
        #expect(try JSONDecoder().decode(AccountRegistry.self, from: data) == registry)
    }
}
