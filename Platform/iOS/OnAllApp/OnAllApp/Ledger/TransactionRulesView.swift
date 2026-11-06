import NEOBudgetCalendar
import SwiftUI

/// 설정 → 자동 분류 규칙: the rules that rename and categorize transactions by their original name.
struct TransactionRulesView: View {
    let model: AppModel
    @State private var editing: TransactionRule?

    private var rules: [TransactionRule] { model.transactionOverrides.rules.sorted { $0.createdAtUnixMilliseconds > $1.createdAtUnixMilliseconds } }

    var body: some View {
        List {
            if rules.isEmpty {
                Section {
                    Text("아직 규칙이 없어요. 오른쪽 위 +로 만들어 보세요.").foregroundStyle(Theme.textSecondary)
                }
                .onAllCardRow()
            } else {
                Section {
                    ForEach(rules) { rule in
                        Button { editing = rule } label: { row(rule) }
                    }
                    .onDelete { offsets in
                        for index in offsets { model.deleteRule(id: rules[index].id) }
                    }
                } footer: {
                    Text("규칙은 거래를 보여줄 때만 적용돼요. 지우면 원래 이름과 분류로 돌아가요. 직접 고친 내용이 있으면 그쪽이 먼저예요.")
                }
                .onAllCardRow()
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("자동 분류 규칙")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = Self.blankRule(now: model.nowMilliseconds) } label: { Image(systemName: "plus") }
            }
        }
        .sheet(item: $editing) { rule in TransactionRuleEditSheet(rule: rule, model: model) }
    }

    static func blankRule(now: Int64) -> TransactionRule {
        .init(id: UUID().uuidString, label: nil, mode: .contains, pattern: "", actions: [], createdAtUnixMilliseconds: now)
    }

    private func row(_ rule: TransactionRule) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            Text(rule.label ?? "\(Self.modeName(rule.mode)) '\(rule.pattern)'").font(Theme.Typo.rowTitle)
                .foregroundStyle(rule.isEnabled ? Theme.textPrimary : Theme.textTertiary)
            Text(Self.summary(rule) + (rule.isEnabled ? "" : " · 꺼짐")).font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary)
        }
    }

    static func modeName(_ mode: TransactionRule.MatchMode) -> String {
        switch mode {
        case .exact: "이름이 같음"
        case .contains: "이름에 포함"
        case .regex: "정규식"
        }
    }

    static func summary(_ rule: TransactionRule) -> String {
        rule.actions.map { action -> String in
            switch action {
            case let .setTitle(title): "이름 → \(title)"
            case let .replace(find, with, _): with.isEmpty ? "'\(find)' 지우기" : "'\(find)' → '\(with)'"
            case let .setCategory(category): "분류 → \(CategoryIcon.name(for: category) ?? category.rawValue)"
            case let .addTags(tags): tags.map { "#" + $0 }.joined(separator: " ")
            }
        }.joined(separator: " · ")
    }
}

/// Writes one rule: what name to look for, then what to do to the transaction.
struct TransactionRuleEditSheet: View {
    struct Replacement: Identifiable, Equatable {
        let id = UUID()
        var find = ""
        var with = ""
        var isRegex = false
    }

    let rule: TransactionRule
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var mode: TransactionRule.MatchMode
    @State private var pattern: String
    @State private var isEnabled: Bool
    @State private var newTitle: String
    @State private var replacements: [Replacement]
    @State private var category: CanonicalCategoryID?
    @State private var tags: String
    @State private var titles: [String] = []

    init(rule: TransactionRule, model: AppModel) {
        self.rule = rule
        self.model = model
        _mode = State(initialValue: rule.mode)
        _pattern = State(initialValue: rule.pattern)
        _isEnabled = State(initialValue: rule.isEnabled)
        var title = ""
        var swaps: [Replacement] = []
        var chosen: CanonicalCategoryID?
        var tagList: [String] = []
        for action in rule.actions {
            switch action {
            case let .setTitle(text): title = text
            case let .replace(find, with, isRegex): swaps.append(.init(find: find, with: with, isRegex: isRegex))
            case let .setCategory(category): chosen = category
            case let .addTags(more): tagList += more
            }
        }
        _newTitle = State(initialValue: title)
        _replacements = State(initialValue: swaps)
        _category = State(initialValue: chosen)
        _tags = State(initialValue: tagList.map { "#" + $0 }.joined(separator: " "))
    }

    private var draft: TransactionRule {
        var actions: [TransactionRule.Action] = replacements.filter { !$0.find.isEmpty }.map { .replace(find: $0.find, with: $0.with, isRegex: $0.isRegex) }
        if let title = TransactionOverride.clean(newTitle) { actions.append(.setTitle(title)) }
        if let category { actions.append(.setCategory(category)) }
        let parsed = TransactionOverride.parseTags(tags)
        if !parsed.isEmpty { actions.append(.addTags(parsed)) }
        var copy = rule
        copy.mode = mode
        copy.pattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.actions = actions
        copy.isEnabled = isEnabled
        return copy
    }

    private var canSave: Bool { draft.isValid && !draft.actions.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("찾는 방법", selection: $mode) {
                        ForEach(TransactionRule.MatchMode.allCases, id: \.self) { Text(TransactionRulesView.modeName($0)).tag($0) }
                    }
                    TextField(mode == .regex ? "정규식 (예: ^Metro.*)" : "원래 거래 이름", text: $pattern)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: {
                    Text("이런 이름이면")
                } footer: {
                    if !pattern.isEmpty, mode == .regex, !draft.isValid {
                        Text("정규식을 읽을 수 없어요.").foregroundStyle(Theme.danger)
                    } else if draft.isValid {
                        Text("지금 내역 중 \(TransactionRuleSet.matchCount(draft, in: titles))건이 해당해요. 대소문자와 띄어쓰기는 구분하지 않아요.")
                    }
                }
                Section {
                    ForEach($replacements) { $swap in
                        VStack(alignment: .leading) {
                            TextField("찾을 글자", text: $swap.find).textInputAutocapitalization(.never).autocorrectionDisabled()
                            TextField("바꿀 글자 (비우면 지워요)", text: $swap.with).textInputAutocapitalization(.never).autocorrectionDisabled()
                            Toggle("정규식", isOn: $swap.isRegex)
                        }
                    }
                    .onDelete { replacements.remove(atOffsets: $0) }
                    Button("글자 바꾸기 추가") { replacements.append(.init()) }
                } header: {
                    Text("이름에서 글자 바꾸기")
                } footer: {
                    Text("예: '점'으로 끝나는 지점명 지우기는 찾을 글자 ' \\S+점$'(정규식), 바꿀 글자는 비워 두면 돼요.")
                }
                Section("이름을 통째로 바꾸기") { TextField("표시할 이름 (비우면 그대로)", text: $newTitle) }
                Section("분류") {
                    Picker("분류", selection: $category) {
                        Text("바꾸지 않음").tag(CanonicalCategoryID?.none)
                        ForEach(CategoryIcon.choices, id: \.id) { choice in
                            Label(choice.name, systemImage: choice.symbol).tag(Optional(CanonicalCategoryID(rawValue: choice.id)))
                        }
                    }
                    .pickerStyle(.navigationLink)
                }
                Section("태그") { TextField("#태그 (띄어쓰기로 구분)", text: $tags).textInputAutocapitalization(.never) }
                Section { Toggle("이 규칙 사용", isOn: $isEnabled) }
                if model.transactionOverrides.rules.contains(where: { $0.id == rule.id }) {
                    Section { Button("규칙 지우기", role: .destructive) { model.deleteRule(id: rule.id); dismiss() } }
                }
            }
            .navigationTitle("자동 분류 규칙")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("저장") { model.saveRule(draft); dismiss() }.disabled(!canSave) }
            }
            .task { titles = await model.ledgerTitles() }
        }
    }
}
