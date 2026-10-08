import Foundation
import NEOBudgetCalendar
import NEOBudgetCore

/// Synthetic transactions built through the real draft -> assembler -> promotion path, so the sample day contains
/// the same entry kinds a real ledger would: spending, a card purchase, a refund, and money movement that must
/// not show up as spending. Nothing here is real data.
enum SampleLedger {
    private static let bank = AccountID(rawValue: "sample-bank")
    private static let savings = AccountID(rawValue: "sample-savings")
    private static let card = CreditInstrumentID(rawValue: "sample-card")

    static func make(today: LocalDate, zone: DisplayTimeZone) throws -> AppLedger {
        let configuration = LedgerConfiguration(
            accounts: [
                Account(id: bank, name: "생활비", kind: .bank, openingBalance: try Money(minorUnits: 1_000_000, currency: "KRW")),
                Account(id: savings, name: "저축", kind: .bank, openingBalance: try Money(minorUnits: 0, currency: "KRW")),
            ],
            creditInstruments: [try CreditInstrument(id: card, name: "카드", currency: "KRW")]
        )
        let month = try BudgetMonth(year: today.year, month: today.month)

        func instant(_ hour: Int, _ minute: Int) -> Int64 { zone.instant(of: today, minuteOfDay: hour * 60 + minute) }
        let restaurantEntry = LedgerEntryID(rawValue: "entry/\(entryKey("sample-restaurant"))")

        func candidate(
            _ id: String, _ kind: DraftEventKind, _ direction: TransactionDirection, _ amount: Int64, _ time: Int64,
            merchant: String? = nil, card onCard: Bool = false, exact: Bool = true, original: String? = nil
        ) throws -> TransactionCandidate {
            let draft = try TransactionCandidateDraft(
                rawNotificationID: id, parserID: "sample", parserVersion: "1", ruleID: id, kind: kind, direction: direction,
                amount: try Money(minorUnits: amount, currency: "KRW"),
                occurredAt: ObservedTimestamp(unixMilliseconds: time, precision: .minute, source: exact ? .text : .notificationTime),
                counterparty: DraftCounterparty(merchantRaw: merchant),
                evidence: original.map { [DraftEvidence(kind: .originalApprovalReference, strength: .relation, value: $0)] } ?? [],
                confidence: .high
            )
            let context = try CandidateAssemblyContext(
                timeZoneIdentifier: zone.identifier,
                transferCounterpartAccountID: savings,
                cardPaymentInstrumentID: card,
                adjustmentOriginalsByEvidenceValue: original.map { [$0: AdjustmentOriginal(entryID: restaurantEntry, budgetMonth: month)] } ?? [:],
                policyVersion: "sample"
            )
            return try DefaultTransactionCandidateAssembler().assemble(
                draft, resolution: .resolved(onCard ? .creditInstrument(card) : .account(bank)), context: context
            )
        }

        let candidates = [
            try candidate("sample-salary", .deposit, .inflow, 2_000_000, instant(9, 0)),
            try candidate("sample-restaurant", .purchase, .outflow, 12_000, instant(12, 20), merchant: "성수 식당"),
            try candidate("sample-cafe", .purchase, .outflow, 4_800, instant(12, 30), merchant: "카페", card: true, exact: false),
            try candidate("sample-convenience", .purchase, .outflow, 3_500, instant(14, 5), merchant: "편의점"),
            try candidate("sample-transfer", .transferOut, .outflow, 100_000, instant(15, 0)),
            try candidate("sample-bill", .cardBillPayment, .outflow, 15_000, instant(18, 0)),
            try candidate("sample-refund", .refund, .inflow, 5_000, instant(20, 10), original: "sample-restaurant-approval"),
            try candidate("sample-delivery", .purchase, .outflow, 6_200, instant(21, 30), merchant: "배달", card: true, exact: false),
        ]
        return try AppLedger(configuration: configuration, promoting: candidates)
    }

    /// Mirrors the assembler's id scheme (`prefix/<utf8 length>:<raw id>/<event index>`) so the refund can name its original.
    private static func entryKey(_ rawID: String) -> String { "\(rawID.utf8.count):\(rawID)/0" }
}
