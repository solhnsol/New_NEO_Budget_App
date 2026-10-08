import Foundation
import Testing
@testable import NEOBudgetCore

/// Fixtures are synthetic. They reproduce the shapes and risks seen in real data: one institution under two
/// app names, several accounts behind one app, notifications that carry no identifier, and look-alike numbers.
@Suite struct AccountResolutionTests {
    private let extractor = AccountHintExtractor()
    private let woori = InstitutionID(rawValue: "woori")
    private let hyundai = InstitutionID(rawValue: "hyundaicard")

    private func note(_ app: String, _ body: String, id: String = "n1") -> RawNotification {
        RawNotification(id: id, source: NotificationSource(applicationIdentifier: "x.\(id)", displayName: app),
                        capturedAtUnixMilliseconds: 1_000, body: body)
    }

    private func wooriNote(_ number: String, app: String = "우리WON뱅킹", id: String = "n1") -> RawNotification {
        note(app, "[Web발신]\n출금 12,000원\n\(number)\n잔액 1,234,000원\n10/09 12:00:00", id: id)
    }

    private func money(_ value: Int64) -> Money { try! Money(minorUnits: value, currency: "KRW") }

    private var counter = 0
    private func registryWithTwoWooriAccounts() throws -> (AccountRegistry, ResolvedLedgerBinding, ResolvedLedgerBinding) {
        var registry = AccountRegistry()
        let a = ResolvedLedgerBinding.account(AccountID(rawValue: "acc-a"))
        let b = ResolvedLedgerBinding.account(AccountID(rawValue: "acc-b"))
        try registry.adopt(a, displayName: "급여", institution: woori, instrument: .account,
                           identifiers: [.accountNumber(MaskedNumber("1002-123-456***")!)])
        try registry.adopt(b, displayName: "생활비", institution: woori, instrument: .account,
                           identifiers: [.accountNumber(MaskedNumber("1002-999-111***")!)])
        return (registry, a, b)
    }

    // MARK: Extraction

    @Test func bothWooriAppsAreOneInstitution() {
        let a = extractor.hints(from: wooriNote("1002-123-456***", app: "우리WON뱅킹"))
        let b = extractor.hints(from: wooriNote("1002-123-456***", app: "우리은행"))
        #expect(a.institution == woori && b.institution == woori)
        #expect(a.identifier == b.identifier && a.identifier != nil)
        #expect(a.instrument == .account)
    }

    @Test func lookAlikeNumbersAreNotIdentifiers() {
        for body in ["결제 99,000원 2026-10-09 12:00", "문의 010-1234-5678", "승인 12,345,678원", "카드 사용 5,000원"] {
            let hints = extractor.hints(from: note("현대카드", body))
            #expect(hints.identifier == nil, "\(body)")
        }
    }

    @Test func nameMaskIsNotAnIdentifier() {
        let hints = extractor.hints(from: note("카카오페이", "송금 5,000원 (홍*동)"))
        #expect(hints.identifier == nil)
    }

    @Test func shortMaskedNumberIsWeakAndNotBindable() {
        let hints = extractor.hints(from: note("우리은행", "출금 1,000원 12-34-5*"))
        #expect(hints.identifier == nil)
        #expect(hints.hasWeakIdentifier)
    }

    @Test func cardTailIsReadFromTheCardWordOrStars() {
        #expect(extractor.hints(from: note("현대카드", "승인 3,000원 카드(4321)")).identifier == .cardTail("4321"))
        #expect(extractor.hints(from: note("현대카드", "승인 3,000원 ****4321")).identifier == .cardTail("4321"))
        #expect(extractor.hints(from: note("현대카드", "승인 3,000원 카드(4321)")).instrument == .card)
    }

    @Test func institutionComesFromTheSourceNotTheText() {
        let hints = extractor.hints(from: note("Toss", "우리은행 출금 1,000원"))
        #expect(hints.institution == InstitutionID(rawValue: "toss"))
        #expect(extractor.hints(from: note("???", "x")).institution == nil)
        #expect(extractor.hints(from: note("토스뱅크", "x")).institution == InstitutionID(rawValue: "tossbank"))
    }

    // MARK: Matching and the multi-account risk

    @Test func identifierBindsToExactlyItsAccount() throws {
        let (registry, a, b) = try registryWithTwoWooriAccounts()
        let first = registry.resolve(extractor.hints(from: wooriNote("1002-123-456***")))
        let second = registry.resolve(extractor.hints(from: wooriNote("1002-999-111***", app: "우리은행")))
        guard case let .resolved(boundA, _) = first, case let .resolved(boundB, _) = second else {
            Issue.record("expected resolved"); return
        }
        #expect(boundA == a && boundB == b)
    }

    @Test func sameAppDifferentAccountNeverFallsToTheOther() throws {
        let (registry, _, _) = try registryWithTwoWooriAccounts()
        let decision = registry.resolve(extractor.hints(from: wooriNote("1002-555-777***")))
        guard case .newCandidate = decision else { Issue.record("expected candidate, got \(decision)"); return }
    }

    @Test func overlappingMasksMatchingTwoAccountsAreAConflict() throws {
        // The registry refuses to create this state (see the next test); decoded or migrated data could still hold it.
        func profile(_ id: String, _ mask: String) -> AccountProfile {
            AccountProfile(binding: .account(AccountID(rawValue: id)), displayName: id, institution: woori,
                           instrument: .account, identifiers: [.accountNumber(MaskedNumber(mask)!)], isActive: true)
        }
        let registry = AccountRegistry(profiles: [profile("a", "1002-123-4567**"), profile("b", "1002-123-45**89")])
        let seen = AccountHints(institution: woori, instrument: .account, sourceApplication: "x",
                                identifier: .accountNumber(MaskedNumber("1002-123-4567**")!))
        #expect(registry.resolve(seen) == .needsConfirmation(.identifierMatchesMultipleAccounts, suggestion: nil))
    }

    @Test func registryRefusesToBindCompatibleIdentifiersToTwoAccounts() throws {
        var registry = AccountRegistry()
        let a = ResolvedLedgerBinding.account(AccountID(rawValue: "a"))
        let b = ResolvedLedgerBinding.account(AccountID(rawValue: "b"))
        try registry.adopt(a, displayName: "A", institution: woori, instrument: .account,
                           identifiers: [.accountNumber(MaskedNumber("1002-123-4567**")!)])
        #expect(throws: (any Error).self) {
            try registry.adopt(b, displayName: "B", institution: woori, instrument: .account,
                               identifiers: [.accountNumber(MaskedNumber("1002-123-45**89")!)])
        }
    }

    @Test func sameDigitsAtAnotherInstitutionDoNotMatch() throws {
        let (registry, _, _) = try registryWithTwoWooriAccounts()
        let other = AccountHints(institution: InstitutionID(rawValue: "kb"), instrument: .account, sourceApplication: "x",
                                 identifier: .accountNumber(MaskedNumber("1002-123-456***")!))
        guard case .newCandidate = registry.resolve(other) else { Issue.record("must not cross institutions"); return }
    }

    @Test func unknownInstitutionNeverBinds() throws {
        let (registry, _, _) = try registryWithTwoWooriAccounts()
        let hints = extractor.hints(from: note("???", "출금 1,000원 1002-123-456***"))
        #expect(registry.resolve(hints) == .needsConfirmation(.institutionUnknown, suggestion: nil))
    }

    // MARK: Notifications without identifier

    private func cardNoIdentifier() -> AccountHints {
        extractor.hints(from: note("현대카드", "승인 15,000원 일시불"))
    }

    @Test func noIdentifierAndNoRuleAsksTheUser() {
        #expect(AccountRegistry().resolve(cardNoIdentifier()) == .needsConfirmation(.noIdentifier, suggestion: nil))
    }

    @Test func ruleBindsOnlyWhileTheTargetIsTheOnlyCardAtTheInstitution() throws {
        var registry = AccountRegistry()
        let one = ResolvedLedgerBinding.creditInstrument(CreditInstrumentID(rawValue: "c1"))
        try registry.adopt(one, displayName: "현대 M", institution: hyundai, instrument: .card)
        try registry.addSourceRule(id: SourceRuleID(rawValue: "r1"), institution: hyundai, instrument: .card,
                                   binding: one, createdAtUnixMilliseconds: 1)
        guard case let .resolved(bound, .exclusiveSourceRule) = registry.resolve(cardNoIdentifier()) else {
            Issue.record("expected rule resolution"); return
        }
        #expect(bound == one)

        // A second card appears (real data: one card app, two accounts behind it). The same message could now be either.
        let two = ResolvedLedgerBinding.creditInstrument(CreditInstrumentID(rawValue: "c2"))
        try registry.adopt(two, displayName: "현대 X", institution: hyundai, instrument: .card)
        #expect(registry.resolve(cardNoIdentifier()) == .needsConfirmation(.sourceRuleHasSiblingAccounts, suggestion: one))
    }

    @Test func ruleCreationNeedsAcknowledgementWhenSiblingsExist() throws {
        var registry = AccountRegistry()
        let one = ResolvedLedgerBinding.creditInstrument(CreditInstrumentID(rawValue: "c1"))
        let two = ResolvedLedgerBinding.creditInstrument(CreditInstrumentID(rawValue: "c2"))
        try registry.adopt(one, displayName: "A", institution: hyundai, instrument: .card)
        try registry.adopt(two, displayName: "B", institution: hyundai, instrument: .card)
        #expect(throws: AccountRegistryError.siblingsExist([two])) {
            try registry.addSourceRule(id: SourceRuleID(rawValue: "r"), institution: hyundai, instrument: .card,
                                       binding: one, createdAtUnixMilliseconds: 1)
        }
        try registry.addSourceRule(id: SourceRuleID(rawValue: "r"), institution: hyundai, instrument: .card,
                                   binding: one, acknowledgingSiblings: true, createdAtUnixMilliseconds: 1)
        // Acknowledged, but still only a suggestion.
        #expect(registry.resolve(cardNoIdentifier()) == .needsConfirmation(.sourceRuleHasSiblingAccounts, suggestion: one))
    }

    @Test func aStrongUnknownIdentifierNeverFallsThroughToARule() throws {
        var registry = AccountRegistry()
        let one = ResolvedLedgerBinding.creditInstrument(CreditInstrumentID(rawValue: "c1"))
        try registry.adopt(one, displayName: "A", institution: hyundai, instrument: .card)
        try registry.addSourceRule(id: SourceRuleID(rawValue: "r"), institution: hyundai, instrument: .card,
                                   binding: one, createdAtUnixMilliseconds: 1)
        let newCard = extractor.hints(from: note("현대카드", "승인 9,000원 카드(7777)"))
        guard case .newCandidate = registry.resolve(newCard) else { Issue.record("new card absorbed by rule"); return }
    }

    @Test func ruleDoesNotCrossKindOrApplication() throws {
        var registry = AccountRegistry()
        let one = ResolvedLedgerBinding.account(AccountID(rawValue: "a"))
        let toss = InstitutionID(rawValue: "toss")
        try registry.adopt(one, displayName: "토스 계좌", institution: toss, instrument: .account)
        try registry.addSourceRule(id: SourceRuleID(rawValue: "r"), institution: toss, instrument: .account,
                                   applicationIdentifier: "toss.app", binding: one, createdAtUnixMilliseconds: 1)
        let other = AccountHints(institution: toss, instrument: .account, sourceApplication: "other.app")
        let card = AccountHints(institution: toss, instrument: .card, sourceApplication: "toss.app")
        let match = AccountHints(institution: toss, instrument: .account, sourceApplication: "toss.app")
        #expect(registry.resolve(other) == .needsConfirmation(.noIdentifier, suggestion: nil))
        #expect(registry.resolve(card) == .needsConfirmation(.noIdentifier, suggestion: nil))
        guard case .resolved = registry.resolve(match) else { Issue.record("scoped rule should match"); return }
    }

    // MARK: Candidates

    @Test func newIdentifierBecomesACandidateOncePerNotification() {
        var registry = AccountRegistry()
        let hints = extractor.hints(from: wooriNote("1002-123-456***"))
        let d1 = registry.observe(hints, notificationID: "n1", capturedAtUnixMilliseconds: 100)
        _ = registry.observe(hints, notificationID: "n1", capturedAtUnixMilliseconds: 100)
        _ = registry.observe(hints, notificationID: "n2", capturedAtUnixMilliseconds: 50)
        guard case let .newCandidate(id) = d1, let candidate = registry.candidate(id) else { Issue.record("no candidate"); return }
        #expect(candidate.occurrenceCount == 2)
        #expect(candidate.firstSeenUnixMilliseconds == 50 && candidate.lastSeenUnixMilliseconds == 100)
        #expect(candidate.evidenceNotificationIDs == ["n1", "n2"])
        #expect(registry.profiles.isEmpty)
    }

    @Test func observingWithoutIdentifierCreatesNoCandidate() {
        var registry = AccountRegistry()
        _ = registry.observe(cardNoIdentifier(), notificationID: "n1", capturedAtUnixMilliseconds: 1)
        #expect(registry.candidates.isEmpty)
    }

    @Test func linkingACandidateBindsFutureNotifications() throws {
        var (registry, a, _) = try registryWithTwoWooriAccounts()
        let hints = extractor.hints(from: wooriNote("1002-555-777***"))
        guard case let .newCandidate(id) = registry.observe(hints, notificationID: "n1", capturedAtUnixMilliseconds: 1) else {
            Issue.record("expected candidate"); return
        }
        try registry.link(id, to: a) // the user says it is the same account (e.g. renumbered)
        guard case let .resolved(bound, _) = registry.resolve(hints) else { Issue.record("not bound after link"); return }
        #expect(bound == a)
        #expect(registry.candidate(id)?.status == .linked(a))
        #expect(throws: AccountRegistryError.candidateNotOpen(id)) { try registry.dismiss(id) }
    }

    @Test func linkingAnIdentifierThatAnotherAccountOwnsIsRefused() throws {
        var (registry, a, _) = try registryWithTwoWooriAccounts()
        let id = AccountCandidateID(institution: woori, identifier: .accountNumber(MaskedNumber("1002-999-111***")!))
        // Candidate is created only for unmatched identifiers, so build the state a stale UI could produce.
        registry = AccountRegistry(profiles: registry.profiles, candidates: [
            AccountCandidate(id: id, institution: woori, instrument: .account,
                             identifier: .accountNumber(MaskedNumber("1002-999-111***")!), status: .open,
                             occurrenceCount: 1, firstSeenUnixMilliseconds: 1, lastSeenUnixMilliseconds: 1,
                             evidenceNotificationIDs: ["n"])
        ], rules: [])
        #expect(throws: (any Error).self) { try registry.link(id, to: a) }
    }

    @Test func confirmingAsNewCreatesATargetWithAnInternalID() throws {
        var registry = AccountRegistry()
        let hints = extractor.hints(from: wooriNote("1002-123-456***"))
        guard case let .newCandidate(id) = registry.observe(hints, notificationID: "n1", capturedAtUnixMilliseconds: 1) else {
            Issue.record("expected candidate"); return
        }
        let target = try registry.confirmAsNew(id, displayName: "  월급 통장 ", kind: .account(.bank, openingBalance: money(0)),
                                               makeID: { "acc-001" })
        guard case let .account(account) = target else { Issue.record("expected account"); return }
        #expect(account.id.rawValue == "acc-001")
        #expect(account.name == "월급 통장")
        #expect(registry.profile(target.binding)?.displayName == "월급 통장")
        guard case let .resolved(bound, _) = registry.resolve(hints) else { Issue.record("not bound"); return }
        #expect(bound == target.binding)
    }

    @Test func renamingChangesOnlyTheLabel() throws {
        var (registry, a, _) = try registryWithTwoWooriAccounts()
        let before = registry.resolve(extractor.hints(from: wooriNote("1002-123-456***")))
        try registry.rename(a, to: "비상금")
        #expect(registry.profile(a)?.displayName == "비상금")
        #expect(registry.resolve(extractor.hints(from: wooriNote("1002-123-456***"))) == before)
        #expect(throws: AccountRegistryError.emptyDisplayName) { try registry.rename(a, to: "   ") }
    }

    @Test func dismissedCandidateStaysDismissedButKeepsCounting() throws {
        var registry = AccountRegistry()
        let hints = extractor.hints(from: wooriNote("1002-123-456***"))
        guard case let .newCandidate(id) = registry.observe(hints, notificationID: "n1", capturedAtUnixMilliseconds: 1) else { return }
        try registry.dismiss(id)
        _ = registry.observe(hints, notificationID: "n2", capturedAtUnixMilliseconds: 2)
        #expect(registry.candidate(id)?.status == .dismissed)
        #expect(registry.candidate(id)?.occurrenceCount == 2)
        #expect(registry.openCandidates.isEmpty)
    }

    // MARK: Manual accounts

    @Test func userCanAddAnAccountAndAttachIdentifiersLater() throws {
        var registry = AccountRegistry()
        let target = try registry.addAccount(displayName: "비상금", institution: woori, instrument: .account,
                                             kind: .account(.bank, openingBalance: money(1_000)), makeID: { "acc-9" })
        let hints = extractor.hints(from: wooriNote("1002-123-456***"))
        guard case .newCandidate = registry.resolve(hints) else { Issue.record("no identifier yet"); return }
        try registry.addIdentifier(.accountNumber(MaskedNumber("1002-123-456***")!), to: target.binding)
        guard case .resolved = registry.resolve(hints) else { Issue.record("should bind now"); return }
        #expect(throws: (any Error).self) {
            try registry.addIdentifier(.accountNumber(MaskedNumber("12-34-5*")!), to: target.binding)
        }
    }

    // MARK: Adapter and persistence

    @Test func adapterNeverReportsAConfirmationAsResolved() throws {
        let (registry, a, _) = try registryWithTwoWooriAccounts()
        let known = extractor.hints(from: wooriNote("1002-123-456***", id: "k"))
        let unknown = extractor.hints(from: wooriNote("1002-555-777***", id: "u"))
        let resolver = RegistryAccountResolver(registry: registry) { ["k": known, "u": unknown][$0] }
        func draft(_ id: String) throws -> TransactionCandidateDraft {
            try TransactionCandidateDraft(rawNotificationID: id, parserID: "p", parserVersion: "1", ruleID: "r",
                                          kind: .withdrawal, direction: .outflow, amount: money(1),
                                          occurredAt: ObservedTimestamp(unixMilliseconds: 1, precision: .second, source: .text),
                                          confidence: .high)
        }
        #expect(try resolver.resolve(draft("k")) == .resolved(a))
        #expect(try resolver.resolve(draft("u")) == .unresolved(.unknownAccount))
        #expect(try resolver.resolve(draft("zzz")) == .unresolved(.unboundSource))
    }

    @Test func registryRoundTripsThroughCodable() throws {
        var (registry, _, _) = try registryWithTwoWooriAccounts()
        _ = registry.observe(extractor.hints(from: wooriNote("1002-555-777***")), notificationID: "n", capturedAtUnixMilliseconds: 1)
        let data = try JSONEncoder().encode(registry)
        #expect(try JSONDecoder().decode(AccountRegistry.self, from: data) == registry)
    }
}
