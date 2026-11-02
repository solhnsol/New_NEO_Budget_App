import Foundation
import Testing
@testable import NEOBudgetCore
import NEOBudgetInMemoryStorage

/// A payment that is cancelled: the purchase stays in the ledger and the cancellation is added against it, so the spending
/// nets to zero while the account still moves exactly as the bank's statement does (`docs/ledger-behavior.md`).
/// Every order of arrival gives the same ledger: the bank sends a payment and its cancellation within one second.
@Suite struct CancellationTests {
    private let zone = TimeZone(identifier: "Asia/Seoul")!
    private let intake = NotificationIntake(timeZoneIdentifier: "Asia/Seoul")
    private let account = AccountID(rawValue: "account-1")
    /// 2026-10-02 19:14 KST, when the shortcut delivered everything below (the delivery time, never the payment time).
    private let received: Int64 = 1_790_936_040_000

    private func payload(_ app: String, title: String = "", body: String, at time: String) -> String {
        let fields = ["app": app, "title": title, "subtitle": "", "body": body, "timestamp": "Oct 2, 2026 at \(time)"]
        return String(data: try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), encoding: .utf8)!
    }

    private func notification(_ app: String, _ body: String, at time: String) throws -> RawNotification {
        try ShortcutNotificationDecoder(timeZone: zone).decode(payload(app, body: body, at: time), receivedAtUnixMilliseconds: received)[0]
    }

    private func card(_ word: String, _ amount: String, _ shop: String, clock: String, delivered: String, approval: String? = nil, original: String? = nil) throws -> RawNotification {
        let references = [original.map { "원승인번호 \($0)" }, approval.map { "승인번호 \($0)" }].compactMap { $0 }
        let body = (["김가명 님, 현대 체크 \(word) \r\n\(amount)원 일시불, 10/02 \(clock) \r\n\(shop)"] + references).joined(separator: "\r\n")
        return try notification("현대카드", body, at: delivered)
    }

    private func bank(_ word: String, _ amount: String, clock: String, delivered: String) throws -> RawNotification {
        try notification("우리WON뱅킹", "[Web발신]\n우리 \(word) \(amount)원 1002-123-456*** 잔액 1,234,000원 10/02 \(clock)", at: delivered)
    }

    /// A Woori account that the Hyundai check card is linked to, built the way the user would confirm it.
    private func registeredSetup(_ unused: [RawNotification] = []) throws -> IntakeSetup {
        var setup = IntakeSetup()
        var repository = try InMemoryCandidateProcessingRepository(configuration: setup.configuration)
        // Each institution is seen once so that it becomes a candidate account the user can confirm.
        for notification in [try card("승인", "1,111", "시작", clock: "08:00", delivered: "8:00:00 AM"), try bank("출금", "1,111", clock: "08:00:01", delivered: "8:00:01 AM")] {
            _ = try intake.ingest(notification, setup: &setup, repository: &repository)
        }
        let bank = try #require(setup.registry.openCandidates.first { $0.key.institution == .woori })
        let card = try #require(setup.registry.openCandidates.first { $0.key.institution == .hyundaiCard })
        let target = try setup.confirmAsNew(bank.id, displayName: "생활비", kind: .account(.bank, openingBalance: Money(minorUnits: 0, currency: "KRW")),
                                            makeID: { "account-1" })
        try setup.link(card.id, to: target.binding)
        return setup
    }

    private struct Result {
        let snapshot: CandidateProcessingSnapshot
        /// Candidates that neither became an entry nor are evidence of another notification: what the user would be asked about.
        var open: [StoredTransactionCandidate] {
            snapshot.candidates.values.filter { $0.promotedEntryID == nil && $0.corroborates == nil }
        }
        var kinds: [LedgerEntry.Kind] { snapshot.ledger.entries.map(\.kind).sorted { "\($0)" < "\($1)" } }
    }

    private func replay(_ notifications: [RawNotification], setup: IntakeSetup) throws -> Result {
        var setup = setup
        var repository = try InMemoryCandidateProcessingRepository(configuration: setup.configuration)
        for notification in notifications { _ = try intake.ingest(notification, setup: &setup, repository: &repository) }
        return Result(snapshot: try repository.processingSnapshot())
    }

    private func permutations<T>(_ items: [T]) -> [[T]] {
        guard items.count > 1 else { return [items] }
        return items.indices.flatMap { index -> [[T]] in
            var rest = items
            let head = rest.remove(at: index)
            return permutations(rest).map { [head] + $0 }
        }
    }

    private func won(_ amount: Int64) -> Money { try! Money(minorUnits: amount, currency: "KRW") }

    // MARK: A check card payment and its cancellation

    @Test func theFourAlertsOfACancelledCardPaymentNetToZeroInEveryOrderOfArrival() throws {
        let alerts = [
            try card("승인", "8,000", "가게A", clock: "12:10", delivered: "12:10:04 PM"),
            try bank("출금", "8,000", clock: "12:10:03", delivered: "12:10:05 PM"),
            try card("승인취소", "8,000", "가게A", clock: "12:41", delivered: "12:41:01 PM"),
            try bank("출금취소", "8,000", clock: "12:41:02", delivered: "12:41:03 PM"),
        ]
        let setup = try registeredSetup(alerts)
        for order in permutations(alerts) {
            let result = try replay(order, setup: setup)
            #expect(result.kinds == [.adjustment, .expense], "order: \(order.map { String($0.id.prefix(4)) })")
            #expect(result.snapshot.ledger.accountBalances[account] == (won(0)))
            #expect(result.open.isEmpty)
            // One expense and one cancellation against it; the other two alerts are evidence.
            let adjustment = try #require(result.snapshot.ledger.entries.first { $0.kind == .adjustment })
            let expense = try #require(result.snapshot.ledger.entries.first { $0.kind == .expense })
            #expect(adjustment.adjustment?.originalEntryID == expense.id)
            #expect(adjustment.adjustment?.reason == .cancellation)
            #expect(adjustment.budgetImpact?.attributedMonth == expense.budgetImpact?.attributedMonth)
        }
    }

    @Test func aCancellationOfAPartOfAPaymentReturnsOnlyThatPart() throws {
        let alerts = [
            try card("승인", "8,000", "가게A", clock: "12:10", delivered: "12:10:04 PM"),
            try card("승인취소", "3,000", "가게A", clock: "12:41", delivered: "12:41:01 PM"),
        ]
        let setup = try registeredSetup(alerts)
        for order in permutations(alerts) {
            let result = try replay(order, setup: setup)
            #expect(result.kinds == [.adjustment, .expense])
            #expect(result.snapshot.ledger.accountBalances[account] == (won(-5_000)))
            #expect(result.open.isEmpty)
        }
    }

    @Test func aCancellationFindsTheLatestPaymentBeforeItAndEachPaymentIsCancelledOnce() throws {
        // The same shop and amount on two days (the bank's alert of the cancellation names neither).
        let first = try card("승인", "8,000", "가게A", clock: "09:00", delivered: "9:00:04 AM")
        let second = try card("승인", "8,000", "가게A", clock: "12:10", delivered: "12:10:04 PM")
        let cancel = try card("승인취소", "8,000", "가게A", clock: "12:41", delivered: "12:41:01 PM")
        let again = try card("승인취소", "8,000", "가게A", clock: "12:55", delivered: "12:55:01 PM")
        let setup = try registeredSetup([first, second])
        let one = try replay([first, second, cancel], setup: setup)
        let entries = one.snapshot.ledger.entries
        let expenses = entries.filter { $0.kind == .expense }
        let secondExpense = try #require(expenses.max { $0.occurredAtUnixMilliseconds < $1.occurredAtUnixMilliseconds })
        #expect(try #require(entries.first { $0.kind == .adjustment }).adjustment?.originalEntryID == secondExpense.id)
        let two = try replay([first, second, cancel, again], setup: setup)
        let originals = Set(two.snapshot.ledger.entries.compactMap { $0.adjustment?.originalEntryID })
        #expect(originals.count == 2)
        #expect(two.snapshot.ledger.accountBalances[account] == (won(0)))
        // The order the cancellations arrive in does not matter either.
        let late = try replay([cancel, again, second, first], setup: setup)
        #expect(Set(late.snapshot.ledger.entries.compactMap { $0.adjustment?.originalEntryID }).count == 2)
        #expect(late.snapshot.ledger.accountBalances[account] == (won(0)))
        #expect(late.open.isEmpty)
    }

    @Test func theOriginalApprovalNumberDecidesOverTheLatestPayment() throws {
        let older = try card("승인", "8,000", "가게A", clock: "09:00", delivered: "9:00:04 AM", approval: "11111111")
        let newer = try card("승인", "8,000", "가게A", clock: "12:10", delivered: "12:10:04 PM", approval: "22222222")
        let cancel = try card("승인취소", "8,000", "가게A", clock: "12:41", delivered: "12:41:01 PM", approval: "33333333", original: "11111111")
        let setup = try registeredSetup([older, newer])
        for order in permutations([older, newer, cancel]) {
            let result = try replay(order, setup: setup)
            let adjustment = try #require(result.snapshot.ledger.entries.first { $0.kind == .adjustment })
            let original = try #require(result.snapshot.ledger.entries.first { $0.id == adjustment.adjustment?.originalEntryID })
            let oldest = result.snapshot.ledger.entries.filter { $0.kind == .expense }.min { $0.occurredAtUnixMilliseconds < $1.occurredAtUnixMilliseconds }
            #expect(original.id == oldest?.id)
            #expect(result.snapshot.ledger.accountBalances[account] == (won(-8_000)))
        }
    }

    @Test func aCancellationNothingExplainsStaysForReviewAndChangesNoMoney() throws {
        let purchase = try card("승인", "8,000", "가게A", clock: "12:10", delivered: "12:10:04 PM")
        let otherShop = try card("승인취소", "8,000", "가게Z", clock: "12:41", delivered: "12:41:01 PM")
        let tooMuch = try card("승인취소", "9,000", "가게A", clock: "12:42", delivered: "12:42:01 PM")
        let setup = try registeredSetup([purchase, otherShop])
        let result = try replay([purchase, otherShop, tooMuch], setup: setup)
        #expect(result.kinds == [.expense])
        #expect(result.snapshot.ledger.accountBalances[account] == (won(-8_000)))
        #expect(Set(result.open.flatMap(\.candidate.issues)).contains(.missingOriginalEntry))
    }

    // MARK: A payment from the account itself (no card approval), cancelled

    @Test func aWithdrawalAndItsCancellationCloseEachOtherWithoutAnEntryWhicheverComesFirst() throws {
        // The shape of the RPi example: the bank sends both in the same second, and the cancellation can arrive first.
        let withdrawal = try bank("출금", "12,300", clock: "09:00:07", delivered: "9:00:08 AM")
        let cancellation = try bank("출금취소", "12,300", clock: "09:00:07", delivered: "9:00:08 AM")
        let setup = try registeredSetup([withdrawal])
        for order in [[withdrawal, cancellation], [cancellation, withdrawal]] {
            let result = try replay(order, setup: setup)
            #expect(result.snapshot.ledger.entries.isEmpty)
            #expect(result.open.isEmpty)
            #expect(result.snapshot.candidates.values.allSatisfy { $0.corroborates?.rule == .cancellationPair })
        }
    }

    @Test func aCancellationWithoutItsPaymentWaitsAndIsClosedByThePaymentWhenItComes() throws {
        let withdrawal = try bank("출금", "5,000", clock: "10:00:00", delivered: "10:00:01 AM")
        let cancellation = try bank("출금취소", "5,000", clock: "10:00:00", delivered: "10:00:01 AM")
        let setup = try registeredSetup([withdrawal])
        let waiting = try replay([cancellation], setup: setup)
        #expect(waiting.snapshot.ledger.entries.isEmpty)
        #expect(waiting.open.flatMap(\.candidate.issues) == [.missingOriginalEntry])
        // A cancellation for a different amount does not close it.
        let other = try bank("출금", "5,100", clock: "10:00:00", delivered: "10:00:01 AM")
        #expect(try replay([cancellation, other], setup: setup).open.count == 2)
    }

    @Test func aRepeatedNotificationChangesNothing() throws {
        let alerts = [
            try card("승인", "8,000", "가게A", clock: "12:10", delivered: "12:10:04 PM"),
            try card("승인취소", "8,000", "가게A", clock: "12:41", delivered: "12:41:01 PM"),
            try bank("출금취소", "8,000", clock: "12:41:02", delivered: "12:41:03 PM"),
        ]
        let setup = try registeredSetup(alerts)
        let once = try replay(alerts, setup: setup)
        let twice = try replay(alerts + alerts, setup: setup)
        #expect(twice.snapshot.ledger.entries == once.snapshot.ledger.entries)
        #expect(twice.snapshot.candidates == once.snapshot.candidates)
    }
}
