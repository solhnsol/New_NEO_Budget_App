import Foundation
import NEOBudgetCalendar
import NEOBudgetCore

/// `-demo-preview settlement` (with `-demo-full`): friends owing the user for two purchases, a registered payment to send, and the deposits
/// that come with them, so the settlement screens can be screenshotted. `settlement-late` also moves the hub's clock ahead so the overdue marker
/// shows. Nothing here is real data.
enum DemoSettlement {
    static let modes: Set<String> = ["settlement", "settlement-late"]

    static var isOn: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-demo-preview"), arguments.indices.contains(index + 1) else { return false }
        return modes.contains(arguments[index + 1])
    }

    /// Deposits to add to the demo ledger: one short of what 민수 owes, one from nobody asked.
    static func deposits(today: LocalDate) -> [(name: String, won: Int64, day: LocalDate, minute: Int)] {
        [("민수", 20_000, today.adding(days: -1), 21 * 60 + 5), ("지은", 15_000, today.adding(days: -2), 22 * 60)]
    }

    @MainActor
    static func seed(_ mode: String, on model: AppModel) async {
        let provenance = ActivityEditing.provenance(now: model.nowMilliseconds)
        let people = ["민수", "지은", "하윤"].map { Person(id: PersonID(rawValue: "demo-" + $0), displayName: $0) }
        for person in people { _ = await model.perform(.upsertPerson(person)) }
        let purchases = (await model.ledgerSections() ?? []).flatMap(\.entries).filter { $0.transaction.flow == .spend }
        func ask(_ person: Person, _ won: Int64, for title: String) async {
            guard let origin = purchases.first(where: { $0.transaction.title == title }) else { return }
            _ = await model.perform(.createObligation(CreateObligationInput(
                counterpartyID: person.id, direction: .receivable, currency: "KRW", amount: .exact(won),
                originTransactionID: origin.id, label: SettlementLabel.request, provenance: provenance
            )))
        }
        await ask(people[0], 25_000, for: "마트")
        await ask(people[1], 15_000, for: "영화관")
        _ = await model.perform(.createObligation(CreateObligationInput(
            counterpartyID: people[2].id, direction: .payable, currency: "KRW", amount: .exact(30_000),
            label: SettlementLabel.expected, provenance: provenance
        )))
        if mode == "settlement-late" { model.displayClockOffsetMilliseconds = 15 * 86_400_000 }
    }
}
