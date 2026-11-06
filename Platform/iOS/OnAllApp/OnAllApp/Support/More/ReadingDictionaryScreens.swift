import NEOBudgetCore
import SwiftUI

/// 읽기 사전 목록 (design-v2/settings/shapes-v1.html): 기관별로 묶은 항목, 칩(전체·내 항목·무시·공식), 항목마다 켜고 끄기.
struct ReadingDictionaryScreen: View {
    let model: AppModel
    @State private var dictionary = ReadingDictionary.official
    @State private var counts: [String: Int] = [:]
    @State private var filter = 0
    @State private var busy = false
    @State private var failed = false
    @State private var selected: String?
    @State private var adding = false

    private var entries: [ReadingEntry] {
        // 공식 항목은 고친 것이 있으면 고친 모양으로 보인다.
        let official = dictionary.officialEntries.map { dictionary.officialOverrides[$0.id] ?? $0 }
        return dictionary.userEntries + official
    }

    private var mine: [ReadingEntry] { entries.filter { $0.origin == .user && !$0.action.isIgnore } }
    private var ignored: [ReadingEntry] { entries.filter { $0.origin == .user && $0.action.isIgnore } }
    private var official: [ReadingEntry] { entries.filter { $0.origin == .official } }

    var body: some View {
        SettingsPage(title: "읽기 사전", action: ("추가", { adding = true })) {
            SChipRow(titles: ["전체 \(entries.count)", "내 항목 \(mine.count)", "무시 \(ignored.count)", "공식 \(official.count)"], selection: $filter)
            if failed {
                Text("지금은 바꿀 수 없어요. 잠시 뒤에 다시 해 주세요.").font(Theme.Typo.label).foregroundStyle(Theme.danger)
                    .padding(.horizontal, 28).padding(.top, 12)
            }
            if filter == 0 || filter == 1 { groups(mine, fallback: "내 항목") }
            if filter == 0 || filter == 2, !ignored.isEmpty { section("무시", ignored) }
            if filter == 0 || filter == 3 { groups(official, fallback: "공식") }
        }
        .navigationDestination(isPresented: $adding) { IntakeInboxView(model: model) }
        .navigationDestination(item: $selected) { id in
            if let entry = entries.first(where: { $0.id == id }) {
                ReadingEntryScreen(
                    entry: entry, overridden: dictionary.officialOverrides[id] != nil, enabled: isOn(entry),
                    toggle: { set($0, on: $1) }, revert: { revert($0) }, delete: { delete($0) }
                )
            }
        }
        .task(id: model.dataGeneration) {
            dictionary = await model.readingDictionary()
            counts = await model.readingCounts()
        }
        .opacity(busy ? 0.6 : 1)
        .allowsHitTesting(!busy)
    }

    /// 기관(앱)별로 묶는다. 묶음 이름이 없으면 `fallback`.
    @ViewBuilder
    private func groups(_ list: [ReadingEntry], fallback: String) -> some View {
        let names = list.reduce(into: [String]()) { names, entry in
            let name = entry.group ?? fallback
            if !names.contains(name) { names.append(name) }
        }
        ForEach(names, id: \.self) { name in section(name, list.filter { ($0.group ?? fallback) == name }) }
    }

    private func section(_ title: String, _ list: [ReadingEntry]) -> some View {
        SSection(title: title) {
            ForEach(list) { entry in
                HStack(spacing: 12) {
                    Button { selected = entry.id } label: {
                        HStack(spacing: 12) {
                            STile(icon: entry.action.isIgnore ? "file" : "bank", tone: entry.action.isIgnore ? .neutral : (entry.origin == .user ? .purple : .orange))
                            VStack(alignment: .leading, spacing: 0) {
                                Text(entry.name).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary)
                                if let sub = sub(entry) { Text(sub).font(Theme.Typo.label).foregroundStyle(Theme.textTertiary) }
                            }
                            Spacer(minLength: 8)
                            if entry.origin == .user, let count = counts[entry.id], count > 0 {
                                Text("\(count)건").font(.onAll(size: 15)).foregroundStyle(Theme.textTertiary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Toggle(entry.name, isOn: Binding(get: { isOn(entry) }, set: { set(entry, on: $0) })).labelsHidden().toggleStyle(SToggleStyle())
                }
                .padding(.horizontal, 16).padding(.vertical, 8).frame(minHeight: 52)
                .rowDivider(inset: 64)
            }
        }
    }

    private func sub(_ entry: ReadingEntry) -> String? {
        guard entry.origin == .official else { return nil }
        var parts = [dictionary.officialOverrides[entry.id] != nil ? "공식 · 수정됨" : "공식"]
        if let count = counts[entry.id], count > 0 { parts.append("지난 알림 \(count)건") }
        return parts.joined(separator: " · ")
    }

    private func isOn(_ entry: ReadingEntry) -> Bool {
        entry.origin == .user ? entry.enabled : !dictionary.disabledOfficialIDs.contains(entry.id)
    }

    private func set(_ entry: ReadingEntry, on: Bool) {
        var next = dictionary
        if entry.origin == .user {
            guard let index = next.userEntries.firstIndex(where: { $0.id == entry.id }) else { return }
            next.userEntries[index].enabled = on
        } else if on {
            next.disabledOfficialIDs.remove(entry.id)
        } else {
            next.disabledOfficialIDs.insert(entry.id)
        }
        apply(next)
    }

    private func revert(_ entry: ReadingEntry) {
        var next = dictionary
        next.officialOverrides[entry.id] = nil
        apply(next)
    }

    private func delete(_ entry: ReadingEntry) {
        var next = dictionary
        next.userEntries.removeAll { $0.id == entry.id }
        selected = nil
        apply(next)
    }

    /// 사전을 저장하고 알림을 처음부터 다시 읽는다. 읽는 동안 화면은 잠깐 흐려진다.
    private func apply(_ next: ReadingDictionary) {
        busy = true
        failed = false
        Task {
            let ok = await model.setReadingDictionary(next)
            if ok { dictionary = next; counts = await model.readingCounts() } else { failed = true }
            busy = false
        }
    }
}

/// 항목 하나: 공용 표현과 읽는 값. 공식 항목은 켜고 끄기와 되돌리기, 내 항목은 지우기도 된다.
struct ReadingEntryScreen: View {
    let entry: ReadingEntry
    let overridden: Bool
    let enabled: Bool
    let toggle: (ReadingEntry, Bool) -> Void
    let revert: (ReadingEntry) -> Void
    let delete: (ReadingEntry) -> Void
    @State private var on: Bool

    init(
        entry: ReadingEntry, overridden: Bool, enabled: Bool, toggle: @escaping (ReadingEntry, Bool) -> Void,
        revert: @escaping (ReadingEntry) -> Void, delete: @escaping (ReadingEntry) -> Void
    ) {
        self.entry = entry
        self.overridden = overridden
        self.enabled = enabled
        self.toggle = toggle
        self.revert = revert
        self.delete = delete
        _on = State(initialValue: enabled)
    }

    private var pillText: String { entry.origin == .official ? (overridden ? "공식 · 수정됨" : "공식") : "내 항목" }

    /// 틀에서 읽는 칸들(중복 없이, 나온 순서).
    private var slots: [ReadingSlot] {
        var result: [ReadingSlot] = []
        for condition in entry.conditions {
            guard case let .frame(_, frame) = condition else { continue }
            for case let .slot(name) in ReadingEntryBuilder.pieces(of: frame) {
                if let slot = ReadingSlot.named(name), slot != .free, !result.contains(slot) { result.append(slot) }
            }
        }
        return result
    }

    var body: some View {
        SettingsPage(title: entry.name) {
            HStack { SPill(text: pillText, accent: entry.origin == .official); Spacer() }
                .padding(.horizontal, 28).padding(.top, 12)
            SSection(title: "공용 표현") {
                VStack(alignment: .leading, spacing: 8) {
                    if let app = entry.applicationIdentifier { Text(app).font(Theme.Typo.label).foregroundStyle(Theme.textTertiary) }
                    ForEach(Array(entry.conditions.enumerated()), id: \.offset) { _, condition in condition.expression }
                }
                .font(.onAll(size: 15)).foregroundStyle(Theme.textPrimary).lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 14)
            }
            SSection(title: "읽는 값") {
                switch entry.action {
                case let .ignore(reason): SRow(title: "처리", value: "기록하지 않아요 · \(reason.label)")
                case let .read(outcome):
                    SRow(dot: ReadingSlot.direction.tint, title: "종류", value: outcome.directionWords != nil ? "방향 글자가 정해요" : outcome.kind.label)
                    ForEach(slots.filter { $0 != .direction }, id: \.self) { slot in SRow(dot: slot.tint, title: slot.title, value: slot.area) }
                    if let name = outcome.fixedName { SRow(title: "이름", value: name) }
                }
            }
            if entry.origin == .official, overridden { SButton(title: "공식대로 되돌리기", light: true) { revert(entry) } }
            SSection {
                SToggleRow(title: "이 항목 켜기", isOn: Binding(get: { on }, set: { on = $0; toggle(entry, $0) }))
            }
            if entry.origin == .user { SButton(title: "이 항목 지우기", light: true) { delete(entry) } }
        }
    }
}

extension ReadingCondition {
    /// 공용 표현에 보일 한 줄: 틀은 칸 이름을 색으로, 말 목록은 이어서.
    @ViewBuilder
    var expression: some View {
        switch self {
        case let .frame(_, frame), let .frameContained(_, frame): commonExpressionText(frame)
        case let .contains(_, terms): Text(terms.joined(separator: " · "))
        case .notEmpty: Text("비어 있지 않아요").foregroundStyle(Theme.textTertiary)
        }
    }
}

extension ReadingAction {
    var isIgnore: Bool { if case .ignore = self { true } else { false } }
}

extension DraftEventKind {
    var label: String {
        switch self {
        case .purchase: "결제"
        case .cancellation: "결제 취소"
        case .refund: "환불"
        case .withdrawal: "출금"
        case .deposit: "입금"
        case .transferOut: "이체 보냄"
        case .transferIn: "이체 받음"
        case .cardBillPayment: "카드 대금"
        case .cashWithdrawal: "현금 인출"
        case .walletTopUp: "충전"
        case .purchaseSettlementNotice: "결제 확정 안내"
        case .feeCharge: "수수료"
        }
    }
}

extension TransactionDirection {
    var label: String {
        switch self {
        case .outflow: "나가는 돈"
        case .inflow: "들어오는 돈"
        case .neutral: "정하지 않음"
        }
    }
}

extension NotTransactionReason {
    var label: String {
        switch self {
        case .promotion: "광고"
        case .authentication: "인증"
        case .declined: "승인 거절"
        case .pending: "예정·대기"
        case .request: "요청"
        case .configurationChange: "설정 변경"
        case .balanceInquiry: "잔액 안내"
        case .unrecognized: "읽지 않음"
        }
    }
}
