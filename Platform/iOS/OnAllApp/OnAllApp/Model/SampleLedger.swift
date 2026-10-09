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
        let restaurantEntry = entryID(for: "sample-restaurant")

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
            try candidate("sample-dessert", .purchase, .outflow, 3_000, instant(12, 50), merchant: "디저트"),
            try candidate("sample-parking", .purchase, .outflow, 2_000, instant(12, 55), merchant: "주차"),
            try candidate("sample-snack", .purchase, .outflow, 3_200, instant(13, 20), merchant: "분식"),
            try candidate("sample-cafe", .purchase, .outflow, 4_800, instant(12, 30), merchant: "카페", card: true, exact: false),
            try candidate("sample-convenience", .purchase, .outflow, 3_500, instant(14, 5), merchant: "편의점"),
            try candidate("sample-transfer", .transferOut, .outflow, 100_000, instant(15, 0)),
            try candidate("sample-bill", .cardBillPayment, .outflow, 15_000, instant(18, 0)),
            try candidate("sample-refund", .refund, .inflow, 5_000, instant(20, 10), original: "sample-restaurant-approval"),
            try candidate("sample-delivery", .purchase, .outflow, 6_200, instant(21, 30), merchant: "배달", card: true, exact: false),
        ] + (ProcessInfo.processInfo.arguments.contains("-demo-dense")
            // A burst of purchases a few minutes apart, to see transaction lines that cannot all keep apart.
            ? try (0..<5).map { try candidate("sample-burst-\($0)", .purchase, .outflow, 1_000 + Int64($0) * 100, instant(16, 30 + $0 * 2), merchant: "상점 \($0)") }
            : [])
        // `-demo-trans`: a burst of purchases on each of the days around today (a few minutes apart), for the days that slide in.
        var transBurst: [TransactionCandidate] = []
        if ProcessInfo.processInfo.arguments.contains("-demo-trans") {
            for (offset, minute) in [(-1, 11 * 60 + 5), (1, 14 * 60 + 2), (2, 9 * 60 + 40)] {
                for index in 0..<6 {
                    transBurst.append(try candidate(
                        "trans-\(offset)-\(index)", .purchase, .outflow, 1_000 + Int64(index) * 500,
                        zone.instant(of: today.adding(days: offset), minuteOfDay: minute + index * 3), merchant: "상점 \(index)"
                    ))
                }
            }
        }
        // `-demo-txn`: synthetic spending for checking how transactions are written (see DemoData's `-demo-txn` events and DemoLinks).
        let txnCandidates: [TransactionCandidate] = [
            try candidate("txn-a1", .purchase, .outflow, 4_500, instant(8, 40), merchant: "커피 가"),
            try candidate("txn-over", .purchase, .outflow, 9_800, instant(9, 15), merchant: "택시"),
            try candidate("txn-b1", .purchase, .outflow, 12_000, instant(11, 20), merchant: "식당 하나"),
            try candidate("txn-b2", .purchase, .outflow, 3_000, instant(11, 50), merchant: "디저트 둘"),
            try candidate("txn-b3", .purchase, .outflow, 2_000, instant(12, 20), merchant: "주차 셋"),
            try candidate("txn-b4", .purchase, .outflow, 3_200, instant(12, 50), merchant: "분식 넷"),
            try candidate("txn-b5", .purchase, .outflow, 5_500, instant(13, 20), merchant: "카페 다섯"),
            try candidate("txn-c1", .purchase, .outflow, 1_000, instant(15, 5), merchant: "껌"),
            try candidate("txn-c2", .purchase, .outflow, 1_500, instant(15, 10), merchant: "물"),
            try candidate("txn-c3", .purchase, .outflow, 2_500, instant(15, 15), merchant: "과자"),
            try candidate("txn-ext", .purchase, .outflow, 3_500, instant(16, 30), merchant: "편의점 비"),
            try candidate("txn-late", .purchase, .outflow, 7_700, instant(20, 5), merchant: "야식"),
        ] + (try (0..<5).map { try candidate("txn-burst-\($0)", .purchase, .outflow, 1_000 + Int64($0) * 100, instant(18, $0 * 2), merchant: "상점 \($0)") })
        return try AppLedger(configuration: configuration, promoting: transBurst + (ProcessInfo.processInfo.arguments.contains("-demo-txn-lite") ? Array(txnCandidates.prefix(11))
            : ProcessInfo.processInfo.arguments.contains("-demo-txn") ? txnCandidates : candidates))
    }

    /// Mirrors the assembler's id scheme (`prefix/<utf8 length>:<raw id>/<event index>`) so the refund can name its
    /// original and a demo can link a transaction to an event.
    static func entryID(for rawID: String) -> LedgerEntryID { LedgerEntryID(rawValue: "entry/\(rawID.utf8.count):\(rawID)/0") }
}
