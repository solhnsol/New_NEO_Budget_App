import NEOBudgetCalendar
import NEOBudgetCore
import SwiftUI

/// Changes how one transaction is shown: its name, category, memo and tags. The amount and what the bank reported stay as they are.
struct TransactionEditSheet: View {
    let entry: LedgerListEntry
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var category: CanonicalCategoryID?
    @State private var memo: String
    @State private var tags: [String]

    init(entry: LedgerListEntry, model: AppModel) {
        self.entry = entry
        self.model = model
        _title = State(initialValue: entry.transaction.title ?? "")
        _category = State(initialValue: entry.categoryID)
        _memo = State(initialValue: entry.override?.memo ?? "")
        _tags = State(initialValue: entry.override?.tags ?? [])
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("이름") { TextField("거래 이름", text: $title) }
                Section("분류") {
                    Picker("분류", selection: $category) {
                        Text("분류 안 함").tag(CanonicalCategoryID?.none)
                        ForEach(CategoryIcon.choices, id: \.id) { choice in
                            Label(choice.name, systemImage: choice.symbol).tag(Optional(CanonicalCategoryID(rawValue: choice.id)))
                        }
                    }
                    .pickerStyle(.navigationLink)
                }
                Section {
                    TextField("메모", text: $memo, axis: .vertical)
                    TagField(tags: $tags, suggestions: model.knownTags)
                } header: {
                    Text("메모·태그")
                } footer: {
                    Text("금액과 카드·계좌 내역은 바뀌지 않아요. 이 화면에서 보이는 모습만 바뀌어요.")
                }
                if entry.transaction.id.rawValue.hasPrefix(ManualTransaction.idPrefix) {
                    Section { Button("이 내역 지우기", role: .destructive) { model.removeManual(entry.id); dismiss() } }
                } else if entry.override != nil {
                    Section { Button("원래대로 되돌리기", role: .destructive) { model.edit(entry.id, to: nil); dismiss() } }
                }
            }
            .navigationTitle("거래 수정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("저장") { save() } }
            }
        }
    }

    private func save() {
        let original = entry.transaction.title
        let name = TransactionOverride.clean(title)
        let override = TransactionOverride(
            title: name == original ? entry.override?.title : name,
            category: category,
            memo: TransactionOverride.clean(memo),
            tags: tags
        )
        model.edit(entry.id, to: override)
        dismiss()
    }
}
