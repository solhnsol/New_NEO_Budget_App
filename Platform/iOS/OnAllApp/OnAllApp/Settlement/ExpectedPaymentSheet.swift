import NEOBudgetCalendar
import NEOBudgetCore
import SwiftUI

/// "정산 예정": money the user is about to send (`docs/ledger-behavior.md`, 정산 이후 결정 5). Registered ahead, it is settled by itself when the
/// transfer goes out; the amount may be left empty and then the first transfer to that person decides it.
struct ExpectedPaymentSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var person: PersonID?
    @State private var amountText = ""
    @State private var isSaving = false
    @State private var failed = false
    @FocusState private var typing: Bool

    private var amount: Int64? { Int64(amountText.filter(\.isNumber)).flatMap { $0 > 0 ? $0 : nil } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PeoplePicker(
                        people: model.catalog.people, chosen: person.map { [$0] } ?? [], showsSelf: false, addPrompt: "누구에게 보낼 건가요?",
                        toggle: { person = person == $0 ? nil : $0 },
                        add: { name in Task { await add(name) } }
                    )
                } header: {
                    Text("누구에게 보낼 돈인가요?")
                }
                .onAllCardRow()
                Section {
                    TextField("금액을 몰라도 괜찮아요", text: $amountText)
                        .keyboardType(.numberPad).focused($typing).font(Theme.Typo.amount)
                } header: {
                    Text("얼마예요?")
                } footer: {
                    Text("송금하면 알아서 이 정산에 연결돼요. 금액을 비워 두면 그 사람에게 처음 보내는 돈으로 정해져요.")
                }
                .onAllCardRow()
            }
            .onAllGroupedScreen()
            .navigationTitle("줄 돈 미리 등록")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("완료") { typing = false }.fontWeight(.semibold) }
            }
            .primaryActionBar(isEnabled: person != nil && !isSaving) { Task { await save() } } label: { Text("정산 예정 등록하기") }
            .alert("등록하지 못했어요", isPresented: $failed) { Button("확인", role: .cancel) {} } message: { Text("다시 시도해 주세요.") }
        }
    }

    private func add(_ name: String) async {
        let created = Person(id: PersonID(rawValue: ActivityEditing.newID(prefix: "person")), displayName: name)
        if case .applied? = await model.perform(.upsertPerson(created)) { person = created.id }
    }

    private func save() async {
        guard let person else { return }
        isSaving = true
        defer { isSaving = false }
        let input = CreateObligationInput(
            counterpartyID: person, direction: .payable, currency: "KRW", amount: amount.map { .exact($0) } ?? .unknown,
            label: SettlementLabel.expected, provenance: ActivityEditing.provenance(now: model.nowMilliseconds)
        )
        if case .applied? = await model.perform(.createObligation(input)) { dismiss() } else { failed = true }
    }
}
