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
    @State private var applyToSameName = false
    @State private var showsTags = false

    init(entry: LedgerListEntry, model: AppModel) {
        self.entry = entry
        self.model = model
        _title = State(initialValue: entry.transaction.title ?? "")
        _category = State(initialValue: entry.categoryID)
        _memo = State(initialValue: entry.override?.memo ?? "")
        _tags = State(initialValue: entry.override?.tags ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetTitleLine(canSave: true, save: save) {
                Text("거래 수정").font(Theme.Typo.sheetTitle).foregroundStyle(Theme.textPrimary)
            }
            ScrollView {
                VStack(spacing: 0) {
                    SheetRow("이름") { SheetTextValue(placeholder: "추가", text: $title) }
                    SheetRow("분류") { categoryMenu }
                    SheetRow("메모") { SheetTextValue(placeholder: "추가", text: $memo) }
                    SheetRow("태그", showsDivider: showsTags || canMakeRule || canRemove) {
                        Button { withAnimation(Theme.Motion.press) { showsTags.toggle() } } label: {
                            SheetValue(text: tags.isEmpty ? "추가" : tags.map { "#" + $0 }.joined(separator: " "), isSet: !tags.isEmpty)
                        }
                        .buttonStyle(.plain)
                    }
                    if showsTags { TagField(tags: $tags, suggestions: model.knownTags).padding(.vertical, Theme.Space.m) }
                    if canMakeRule {
                        SheetRow("같은 이름 거래에도 적용", showsDivider: canRemove) { SheetToggle(isOn: $applyToSameName, label: "같은 이름 거래에도 적용") }
                    }
                    if entry.transaction.id.rawValue.hasPrefix(ManualTransaction.idPrefix) {
                        removeButton("이 내역 지우기") { model.removeManual(entry.id); dismiss() }
                    } else if entry.override != nil {
                        removeButton("원래대로 되돌리기") { model.edit(entry.id, to: nil); dismiss() }
                    }
                }
            }
            .scrollIndicators(.hidden).padding(.top, Theme.Space.s)
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.top, Theme.Space.l)
        .onAllSheet(detents: [.large])
        .tint(Theme.accent)
    }

    private var canRemove: Bool { entry.transaction.id.rawValue.hasPrefix(ManualTransaction.idPrefix) || entry.override != nil }

    private func removeButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(Theme.Typo.rowTitle).foregroundStyle(Theme.dangerStrong)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
    }

    private var categoryMenu: some View {
        Menu {
            Picker("분류", selection: $category) {
                Text("안 함").tag(CanonicalCategoryID?.none)
                ForEach(CategoryIcon.choices, id: \.id) { choice in
                    Label(choice.name, systemImage: choice.symbol).tag(Optional(CanonicalCategoryID(rawValue: choice.id)))
                }
            }
        } label: {
            SheetValue(text: CategoryIcon.name(for: category) ?? "안 함", isSet: category != nil)
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
            tags: tags
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
