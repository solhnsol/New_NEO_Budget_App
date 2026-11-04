import NEOBudgetCalendar
import NEOBudgetCore
import SwiftUI

/// Adds a transaction no notification brought in: how much, what, when, its category, memo and tags. It is kept beside the ledger, and shows
/// "직접 입력" so it can be told apart from what the bank reported. Built like the event sheet (`EventCreateSheet`): the main input on top, the rest as rows.
struct ManualTransactionSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var amountText = ""
    @State private var isRefund = false
    @State private var when = Date()
    @State private var category: CanonicalCategoryID?
    @State private var memo = ""
    @State private var tags: [String] = []
    @State private var showsTags = false
    @FocusState private var amountFocused: Bool

    private var won: Int64? { Int64(amountText.filter(\.isNumber)).flatMap { $0 > 0 ? $0 : nil } }
    private var zone: TimeZone { TimeZone(identifier: model.dayZone.identifier) ?? .current }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetTitleLine(canSave: won != nil, save: save) {
                Text("내역 추가").font(Theme.Typo.sheetTitle).foregroundStyle(Theme.textPrimary)
            }
            SheetSegments(options: ["지출", "환불·돌려받음"], selection: Binding(get: { isRefund ? 1 : 0 }, set: { isRefund = $0 == 1 }))
                .padding(.top, Theme.Space.m)
            amount.padding(.top, Theme.Space.xl)
            ScrollView { rows }.scrollIndicators(.hidden).scrollDismissesKeyboard(.interactively).padding(.top, Theme.Space.s)
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.top, Theme.Space.l)
        .onAppear { amountFocused = true }
        .presentationDetents([.large])
        .presentationCornerRadius(Theme.Radius.sheet)
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.surface)
        .tint(Theme.accent)
    }

    /// The number the sheet is about: 32 bold, typed with the number pad and shown with thousands separators.
    private var amount: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            TextField("", text: $amountText, prompt: Text("0").foregroundColor(Theme.disabled))
                .font(Theme.Typo.hero).foregroundStyle(Theme.textPrimary)
                .keyboardType(.numberPad)
                .focused($amountFocused)
                .onChange(of: amountText) { _, text in
                    let grouped = SheetFormat.grouped(text)
                    if grouped != text { amountText = grouped }
                }
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 24, alignment: .leading)
            Text("원").font(Theme.Typo.hero).foregroundStyle(amountText.isEmpty ? Theme.disabled : Theme.textPrimary)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { amountFocused = true }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            SheetRow("이름") { SheetTextValue(placeholder: "추가", text: $title) }
            SheetRow("날짜") { SheetPickerValue(text: SheetFormat.day(when, zone: zone), date: $when, components: .date, zone: zone) }
            SheetRow("시각") { SheetPickerValue(text: SheetFormat.clock(of: when, zone: zone), date: $when, components: .hourAndMinute, zone: zone) }
            SheetRow("분류") { categoryMenu }
            SheetRow("메모", showsDivider: true) { SheetTextValue(placeholder: "추가", text: $memo) }
            SheetRow("태그", showsDivider: showsTags) {
                Button { withAnimation(Theme.Motion.press) { showsTags.toggle() } } label: {
                    SheetValue(text: tags.isEmpty ? "추가" : tags.map { "#" + $0 }.joined(separator: " "), isSet: !tags.isEmpty)
                }
                .buttonStyle(.plain)
            }
            if showsTags { TagField(tags: $tags, suggestions: model.knownTags).padding(.vertical, Theme.Space.m) }
        }
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

    private func save() {
        guard let won else { return }
        let override = TransactionOverride(category: category, memo: TransactionOverride.clean(memo), tags: tags)
        model.addManual(
            title: TransactionOverride.clean(title) ?? "직접 입력", won: won, isRefund: isRefund,
            at: Int64(when.timeIntervalSince1970 * 1_000), override: override
        )
        dismiss()
    }
}
