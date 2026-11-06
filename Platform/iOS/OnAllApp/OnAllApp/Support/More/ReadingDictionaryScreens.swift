import NEOBudgetCore
import SwiftUI

/// 읽기 사전 목록 (design-v2/settings/shapes-v1.html): 공식 항목과 내 항목, 무시 항목. 끄고 켜고, 항목을 열어 읽는 법을 본다.
struct ReadingDictionaryScreen: View {
    let model: AppModel
    @State private var dictionary = ReadingDictionary.official
    @State private var counts: [String: Int] = [:]
    @State private var filter = 0
    @State private var busy = false
    @State private var failed = false
    @State private var selected: String?

    private var entries: [ReadingEntry] {
        // 공식 항목은 고친 것이 있으면 고친 모양으로 보인다.
        let official = dictionary.officialEntries.map { dictionary.officialOverrides[$0.id] ?? $0 }
        return dictionary.userEntries + official
    }

    private var mine: [ReadingEntry] { entries.filter { $0.origin == .user && !$0.action.isIgnore } }
    private var ignored: [ReadingEntry] { entries.filter(\.action.isIgnore) }
    private var official: [ReadingEntry] { entries.filter { $0.origin == .official && !$0.action.isIgnore } }

    var body: some View {
        SettingsPage(title: "읽기 사전") {
            SChipRow(titles: ["전체 \(entries.count)", "내 항목 \(entries.filter { $0.origin == .user }.count)", "무시 \(ignored.count)", "공식 \(entries.filter { $0.origin == .official }.count)"], selection: $filter)
                .padding(.top, 8)
            if failed {
                Text("지금은 바꿀 수 없어요. 잠시 뒤에 다시 해 주세요.").font(Theme.Typo.label).foregroundStyle(Theme.danger)
                    .padding(.horizontal, 28).padding(.top, 12)
            }
            if filter == 0 || filter == 1, !mine.isEmpty { group("내 항목", mine) }
            if filter == 0 || filter == 2, !ignored.isEmpty { group("무시", ignored) }
            if filter == 0 || filter == 3, !official.isEmpty { group("공식", official) }
        }
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

    private func group(_ title: String, _ list: [ReadingEntry]) -> some View {
        SSection(title: title) {
            ForEach(list) { entry in
                HStack(spacing: 12) {
                    Button { selected = entry.id } label: {
                        HStack(spacing: 12) {
                            STile(icon: entry.action.isIgnore ? "file" : "bank", tone: entry.action.isIgnore ? .neutral : (entry.origin == .user ? .purple : .orange))
                            VStack(alignment: .leading, spacing: 0) {
                                Text(entry.name).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary)
                                Text(sub(entry)).font(Theme.Typo.label).foregroundStyle(Theme.textTertiary)
                            }
                            Spacer(minLength: 8)
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

    private func sub(_ entry: ReadingEntry) -> String {
        var parts = [entry.origin == .official ? (dictionary.officialOverrides[entry.id] != nil ? "공식 · 수정됨" : "공식") : "내 항목"]
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

/// 항목 하나: 어떤 알림을 어떻게 읽는지. 공식 항목은 켜고 끄기와 되돌리기만, 내 항목은 지우기도 된다.
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

    var body: some View {
        SettingsPage(title: entry.name) {
            SSection(title: "이런 알림이에요") {
                if let app = entry.applicationIdentifier { SField(label: "받은 앱", value: app) } else { SField(label: "받은 앱", value: "모든 앱") }
                ForEach(Array(entry.conditions.enumerated()), id: \.offset) { _, condition in
                    SField(label: condition.label, value: condition.value)
                }
            }
            SSection(title: "읽은 뒤") {
                switch entry.action {
                case let .ignore(reason): SField(label: "처리", value: "기록하지 않아요 · \(reason.label)")
                case let .read(outcome):
                    SField(label: "종류", value: outcome.kind.label)
                    SField(label: "방향", value: outcome.direction.label)
                    if let name = outcome.fixedName { SField(label: "이름", value: name) }
                }
            }
            SSection {
                SToggleRow(title: "이 항목 켜기", isOn: Binding(get: { on }, set: { on = $0; toggle(entry, $0) }))
            }
            if entry.origin == .official, overridden { SButton(title: "공식대로 되돌리기", light: true) { revert(entry) } }
            if entry.origin == .user { SButton(title: "이 항목 지우기", light: true) { delete(entry) } }
        }
    }
}

private extension ReadingAction {
    var isIgnore: Bool { if case .ignore = self { true } else { false } }
}

private extension ReadingField {
    var label: String {
        switch self {
        case .title: "제목"
        case .subtitle: "부제"
        case .body: "본문"
        case .all: "알림 전체"
        }
    }
}

private extension ReadingCondition {
    var label: String {
        switch self {
        case let .contains(field, _): "\(field.label)에 이 말이 있으면"
        case let .frame(field, _): "\(field.label)이 이 모양이면"
        case let .frameContained(field, _): "\(field.label)에 이 모양이 있으면"
        case let .notEmpty(field): "\(field.label)이 있으면"
        }
    }

    var value: String {
        switch self {
        case let .contains(_, terms): terms.joined(separator: " · ")
        case let .frame(_, frame), let .frameContained(_, frame): frame.replacingOccurrences(of: #"\{re:[^}]*\}"#, with: "…", options: .regularExpression)
        case .notEmpty: "비어 있지 않아요"
        }
    }
}

private extension DraftEventKind {
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

private extension TransactionDirection {
    var label: String {
        switch self {
        case .outflow: "나가는 돈"
        case .inflow: "들어오는 돈"
        case .neutral: "정하지 않음"
        }
    }
}

private extension NotTransactionReason {
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
