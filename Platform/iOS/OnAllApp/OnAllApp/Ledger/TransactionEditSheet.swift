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
    @State private var tags: String
    @State private var applyToSameName = false

    init(entry: LedgerListEntry, model: AppModel) {
        self.entry = entry
        self.model = model
        _title = State(initialValue: entry.transaction.title ?? "")
        _category = State(initialValue: entry.categoryID)
        _memo = State(initialValue: entry.override?.memo ?? "")
        _tags = State(initialValue: (entry.override?.tags ?? []).map { "#" + $0 }.joined(separator: " "))
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
                    TextField("#태그 (띄어쓰기로 구분)", text: $tags).textInputAutocapitalization(.never)
                } header: {
                    Text("메모·태그")
                } footer: {
                    Text("금액과 카드·계좌 내역은 바뀌지 않아요. 이 화면에서 보이는 모습만 바뀌어요.")
                }
                if canMakeRule {
                    Section {
                        Toggle("같은 이름 거래에도 적용", isOn: $applyToSameName)
                    } footer: {
                        Text("켜면 '\(entry.originalTitle ?? "")'(이)라는 이름의 지난 거래와 앞으로 들어올 거래에 이 이름·분류를 자동으로 적용해요. 설정의 '자동 분류 규칙'에서 고치거나 지울 수 있어요.")
                    }
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

    /// A rule keys on the name the ledger has, so typed-in transactions (which have no bank name) cannot make one.
    private var canMakeRule: Bool {
        !entry.transaction.id.rawValue.hasPrefix(ManualTransaction.idPrefix) && !(entry.originalTitle ?? "").isEmpty
    }

    private func save() {
        let shown = entry.transaction.title
        let name = TransactionOverride.clean(title)
        let override = TransactionOverride(
            title: name == shown ? entry.override?.title : name,
            // A category that is just what the rules or allocations already say is not an edit of the user's.
            category: category == entry.categoryWithoutEdit ? nil : category,
            memo: TransactionOverride.clean(memo),
            tags: TransactionOverride.parseTags(tags)
        )
        model.edit(entry.id, to: override, originalTitle: entry.originalTitle)
        if applyToSameName, canMakeRule, let original = entry.originalTitle {
            var actions: [TransactionRule.Action] = []
            if let name, name != original { actions.append(.setTitle(name)) }
            if let category { actions.append(.setCategory(category)) }
            if !override.tags.isEmpty { actions.append(.addTags(override.tags)) }
            if !actions.isEmpty {
                model.saveRule(.init(
                    id: UUID().uuidString, label: nil, mode: .exact, pattern: original, actions: actions, createdAtUnixMilliseconds: model.nowMilliseconds
                ))
            }
        }
        dismiss()
    }
}
