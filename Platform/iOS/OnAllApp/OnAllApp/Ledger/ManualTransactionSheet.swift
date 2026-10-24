import NEOBudgetCalendar
import NEOBudgetCore
import SwiftUI

/// Adds a transaction no notification brought in: what, how much, when, its category, memo and tags. It is kept beside the ledger, and shows
/// "직접 입력" so it can be told apart from what the bank reported.
struct ManualTransactionSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var amountText = ""
    @State private var isRefund = false
    @State private var when = Date()
    @State private var category: CanonicalCategoryID?
    @State private var memo = ""
    @State private var tags = ""

    private var won: Int64? { Int64(amountText.filter(\.isNumber)).flatMap { $0 > 0 ? $0 : nil } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("종류", selection: $isRefund) {
                        Text("지출").tag(false)
                        Text("환불·돌려받음").tag(true)
                    }
                    .pickerStyle(.segmented)
                    TextField("이름 (예: 점심 식사)", text: $title)
                    HStack {
                        TextField("금액", text: $amountText).keyboardType(.numberPad)
                        Text("원").foregroundStyle(Theme.textSecondary)
                    }
                    DatePicker("날짜·시각", selection: $when)
                }
                Section("분류") {
                    Picker("분류", selection: $category) {
                        Text("분류 안 함").tag(CanonicalCategoryID?.none)
                        ForEach(CategoryIcon.choices, id: \.id) { choice in
                            Label(choice.name, systemImage: choice.symbol).tag(Optional(CanonicalCategoryID(rawValue: choice.id)))
                        }
                    }
                    .pickerStyle(.navigationLink)
                }
                Section("메모·태그") {
                    TextField("메모", text: $memo, axis: .vertical)
                    TextField("#태그 (띄어쓰기로 구분)", text: $tags).textInputAutocapitalization(.never)
                }
            }
            .navigationTitle("내역 추가")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("추가") { save() }.disabled(won == nil) }
            }
        }
    }

    private func save() {
        guard let won else { return }
        let override = TransactionOverride(category: category, memo: TransactionOverride.clean(memo), tags: TransactionOverride.parseTags(tags))
        model.addManual(
            title: TransactionOverride.clean(title) ?? "직접 입력", won: won, isRefund: isRefund,
            at: Int64(when.timeIntervalSince1970 * 1_000), override: override
        )
        dismiss()
    }
}
