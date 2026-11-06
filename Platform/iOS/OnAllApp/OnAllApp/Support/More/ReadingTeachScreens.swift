import NEOBudgetCore
import Observation
import SwiftUI

// 읽는 법 알려주기 / 무시하기 (design-v2/settings/shapes-v1.html, 설계 문서 §13.3·§13.7).
// 알림 글을 조각으로 나눠 그 자리에서 칠하고, 고른 조각에 이름을 붙이고, 읽는 법을 확인해 저장한다.

// MARK: - 칸 색과 영역

extension ReadingSlot {
    /// 시안의 칸 색: 방향 분홍, 통장·카드 보라, 금액 파랑, 잔액 청록, 시각 초록, 사람·가게 주황.
    var tint: Color {
        switch self {
        case .direction: Color(rgb: 0xE07C8A)
        case .accountName, .accountNumber, .cardName, .cardNumber, .institution: Color(rgb: 0x9B87E0)
        case .amount: Color(rgb: 0x6B93E8)
        case .balance: Color(rgb: 0x4FB0B8)
        case .time: Color(rgb: 0x5DB38B)
        case .merchant, .payee, .memo, .custom: Color(rgb: 0xE8A25A)
        case .approvalNumber, .free: Color(rgb: 0x9AA1AD)
        }
    }

    /// 읽은 값을 묶는 영역(종류는 따로).
    var area: String {
        switch self {
        case .amount, .balance: "돈"
        case .accountName, .accountNumber, .cardName, .cardNumber, .institution: "계좌와 결제수단"
        case .merchant, .payee, .memo: "사람과 가게"
        case .time: "때"
        case .direction, .custom, .approvalNumber, .free: "그 밖에"
        }
    }

    static func named(_ title: String) -> ReadingSlot? { allCases.first { $0.title == title } }
}

// MARK: - 작업 중인 초안

@Observable @MainActor
final class TeachDraft {
    let model: AppModel
    let notification: RawNotification
    let text: String
    var cuts: Set<Int> = []
    var builder: ReadingEntryBuilder
    /// 조각 id → 칸.
    var assignments: [Int: ReadingSlot] = [:]
    var selected: Set<Int> = []
    var chosenKind: DraftEventKind?
    var name = ""
    var message: String?
    var done: () -> Void = {}

    init(model: AppModel, notification: RawNotification) {
        self.model = model
        self.notification = notification
        let text = NotificationText.joined(notification)
        self.text = text
        builder = ReadingEntryBuilder(text: text)
        // 앱이 확실히 아는 것(종류 글자, 금액, 날짜·시각)은 처음부터 칠해 둔다. 누르면 칠이 풀린다.
        assignments = builder.suggestions()
    }

    var appName: String { notification.source.displayName ?? "알 수 없는 앱" }
    var suggestions: [Int: ReadingSlot] { builder.suggestions().filter { assignments[$0.key] == nil } }

    func tokenText(_ ids: [Int]) -> String {
        var result = ""
        for token in builder.tokens where ids.contains(token.id) {
            result += (result.isEmpty ? "" : (token.spaceBefore ? " " : "")) + token.text
        }
        return result
    }

    var selectedText: String { tokenText(selected.sorted()) }

    func tap(_ token: ReadingEntryBuilder.Token) {
        if assignments[token.id] != nil { assignments[token.id] = nil; return }
        if let slot = suggestions[token.id], !selected.contains(token.id) { assignments[token.id] = slot; return }
        guard token.kind != .symbol else { return }
        if selected.contains(token.id) { selected.remove(token.id); return }
        // 숫자와 글자는 한 번에 같이 이름 붙일 수 없다.
        if let first = selected.first, builder.tokens[first].kind != token.kind { selected = [] }
        selected.insert(token.id)
    }

    func assignSelected(_ slot: ReadingSlot) {
        for id in selected { assignments[id] = slot }
        selected = []
    }

    func acceptSuggestions() { for (id, slot) in suggestions { assignments[id] = slot } }

    func setCuts(_ next: Set<Int>) {
        cuts = next
        builder = ReadingEntryBuilder(text: text, cuts: next)
        assignments = builder.suggestions()
        selected = []
    }

    /// 방향 칸에 읽힌 글자가 정한 종류. 없으면 사용자가 고른 종류.
    var effectiveKind: DraftEventKind? {
        if let token = builder.tokens.first(where: { assignments[$0.id] == .direction }),
           let kind = ReadingEntryBuilder.directionWords[token.text] { return kind }
        return chosenKind
    }

    var kindFromText: Bool { assignments.values.contains(.direction) }

    var readValues: [(slot: ReadingSlot, text: String)] {
        var order: [ReadingSlot] = []
        var texts: [ReadingSlot: String] = [:]
        for token in builder.tokens {
            guard let slot = assignments[token.id], slot != .free, slot != .direction else { continue }
            if !order.contains(slot) { order.append(slot) }
            texts[slot] = (texts[slot].map { $0 + (token.spaceBefore ? " " : "") } ?? "") + token.text
        }
        return order.map { ($0, texts[$0] ?? "") }
    }

    func defaultName() -> String { "\(appName) \(effectiveKind?.label ?? "") 알림".replacingOccurrences(of: "  ", with: " ") }

    func entry(id: String = UUID().uuidString) throws -> ReadingEntry {
        try builder.readEntry(
            name: name.isEmpty ? defaultName() : name, applicationIdentifier: notification.source.applicationIdentifier,
            kind: chosenKind, assignments: assignments, group: appName, id: id
        )
    }

    func save() async {
        do {
            let entry = try entry()
            var dictionary = await model.readingDictionary()
            dictionary.userEntries.append(entry)
            if await model.setReadingDictionary(dictionary) { done() } else { message = "지금은 저장할 수 없어요. 잠시 뒤에 다시 해 주세요." }
        } catch ReadingEntryBuilder.BuildError.needsAmount {
            message = "금액 조각을 골라 이름을 붙여 주세요."
        } catch ReadingEntryBuilder.BuildError.needsKind {
            message = "알림의 종류를 정해 주세요."
        } catch {
            message = "항목 이름을 적어 주세요."
        }
    }
}

// MARK: - 조각이 놓인 원본 글

private struct TokenChip: View {
    enum Look { case plain, selected, assigned(ReadingSlot), suggested(ReadingSlot), fixed }

    let text: String
    let look: Look

    var body: some View {
        Text(text).font(.onAll(size: 15)).foregroundStyle(foreground)
            .padding(.horizontal, 7).frame(minHeight: 30)
            .background(background, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay { border }
    }

    private var foreground: Color {
        if case .fixed = look { return .white }
        return Theme.textPrimary
    }

    private var background: Color {
        switch look {
        case .plain, .suggested: Theme.surface
        case .selected: Theme.accentSoft
        case let .assigned(slot): slot.tint.opacity(0.28)
        case .fixed: Theme.accent
        }
    }

    @ViewBuilder
    private var border: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        switch look {
        case .plain: shape.strokeBorder(Theme.divider, lineWidth: 1)
        case .selected: shape.strokeBorder(Theme.accent, lineWidth: 1.5)
        case let .assigned(slot): shape.strokeBorder(slot.tint, lineWidth: 1.5)
        case let .suggested(slot): shape.strokeBorder(slot.tint, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
        case .fixed: shape.strokeBorder(Theme.accent, lineWidth: 1.5)
        }
    }
}

/// 원본 글: 회색 상자 안에 조각이 줄 그대로 놓인다. 길게 누르면 조각 나누기.
private struct OriginalText: View {
    let builder: ReadingEntryBuilder
    let look: (ReadingEntryBuilder.Token) -> TokenChip.Look
    let tap: (ReadingEntryBuilder.Token) -> Void
    var split: ((ReadingEntryBuilder.Token) -> Void)?

    private var lines: [[ReadingEntryBuilder.Token]] {
        var result: [[ReadingEntryBuilder.Token]] = []
        for token in builder.tokens {
            if token.newlineBefore || result.isEmpty { result.append([token]) } else { result[result.count - 1].append(token) }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                FlowLayout(spacing: 5) {
                    ForEach(line) { token in
                        TokenChip(text: token.text, look: look(token))
                            .onTapGesture { tap(token) }
                            .onLongPressGesture { split?(token) }
                            .accessibilityLabel(token.text)
                            .accessibilityAddTraits(.isButton)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16).padding(.top, 6)
    }
}

private struct AppLine: View {
    let name: String

    var body: some View {
        Text(name).font(Theme.Typo.label).foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 4)
    }
}

// MARK: - 읽는 법 알려주기

struct TeachReadingScreen: View {
    @State private var draft: TeachDraft
    @State private var naming = false
    @State private var next = false
    @State private var choosingKind = false
    @State private var splitting: Int?
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, notification: RawNotification) {
        _draft = State(initialValue: TeachDraft(model: model, notification: notification))
    }

    var body: some View {
        SettingsPage(title: "읽는 법 알려주기", action: ("다음", goNext)) {
            AppLine(name: draft.appName)
            OriginalText(builder: draft.builder, look: look, tap: { draft.tap($0) }, split: { splitting = $0.id })
            addBar
            kindSection
            ForEach(["돈", "계좌와 결제수단", "사람과 가게", "때", "그 밖에"], id: \.self) { area in
                let values = draft.readValues.filter { $0.slot.area == area }
                if !values.isEmpty {
                    SSection(title: area) {
                        ForEach(values, id: \.slot) { value in
                            Button { clear(value.slot) } label: { SRow(dot: value.slot.tint, title: value.slot.title, value: value.text) }
                                .buttonStyle(.onAllRow)
                        }
                    }
                }
            }
            if let message = draft.message {
                Text(message).font(Theme.Typo.label).foregroundStyle(Theme.danger).padding(.horizontal, 28).padding(.top, 12)
            }
        }
        .navigationDestination(isPresented: $naming) { NamePickerScreen(draft: draft) }
        .navigationDestination(isPresented: $next) { ReadingConfirmScreen(draft: draft) }
        .navigationDestination(isPresented: Binding(get: { splitting != nil }, set: { if !$0 { splitting = nil } })) {
            if let id = splitting, draft.builder.tokens.indices.contains(id) { SplitScreen(draft: draft, token: draft.builder.tokens[id]) }
        }
        .confirmationDialog("알림의 종류", isPresented: $choosingKind, titleVisibility: .visible) {
            ForEach(Self.kinds, id: \.self) { kind in Button(kind.label) { draft.chosenKind = kind } }
        }
        .onAppear { draft.done = { dismiss() } }
    }

    private static let kinds: [DraftEventKind] = [
        .purchase, .withdrawal, .deposit, .cancellation, .refund, .transferOut, .transferIn, .cardBillPayment, .walletTopUp,
    ]

    private func look(_ token: ReadingEntryBuilder.Token) -> TokenChip.Look {
        if let slot = draft.assignments[token.id] { return .assigned(slot) }
        if draft.selected.contains(token.id) { return .selected }
        if let slot = draft.suggestions[token.id] { return .suggested(slot) }
        return .plain
    }

    /// 선택한 글이 파랗게 보이는 줄과 `+ 추가`.
    private var addBar: some View {
        let ready = !draft.selected.isEmpty
        return HStack(spacing: 10) {
            Text(ready ? draft.selectedText : "조각을 눌러 고르세요").font(.onAll(size: 15, weight: .medium))
                .foregroundStyle(ready ? Theme.accentStrong : Theme.textTertiary).lineLimit(1)
            Spacer(minLength: 8)
            Button { naming = true } label: {
                Text("+ 추가").font(.onAll(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).frame(height: 32).background(Theme.accent, in: Capsule())
            }
            .buttonStyle(.plain).disabled(!ready).opacity(ready ? 1 : 0.35)
        }
        .padding(.horizontal, 16).frame(minHeight: 52)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .padding(.horizontal, Theme.cardMargin).padding(.top, 12)
    }

    @ViewBuilder
    private var kindSection: some View {
        SSection(title: "종류") {
            if draft.kindFromText {
                SRow(dot: ReadingSlot.direction.tint, title: "종류", value: draft.effectiveKind?.label ?? "")
            } else {
                Button { choosingKind = true } label: {
                    SRow(title: "종류", value: draft.chosenKind?.label ?? "고르기", chevron: true)
                }
                .buttonStyle(.onAllRow)
            }
        }
    }

    private func clear(_ slot: ReadingSlot) {
        for (id, assigned) in draft.assignments where assigned == slot { draft.assignments[id] = nil }
    }

    private func goNext() {
        draft.acceptSuggestions()
        guard draft.assignments.values.contains(.amount) else { draft.message = "금액 조각을 골라 이름을 붙여 주세요."; return }
        guard draft.effectiveKind != nil else { draft.message = "알림의 종류를 정해 주세요."; return }
        draft.message = nil
        next = true
    }
}

// MARK: - 이름 고르기

/// 고른 글에 붙일 이름. 제목은 고른 글이고, 글자 종류에 맞는 이름만 보인다.
private struct NamePickerScreen: View {
    let draft: TeachDraft
    @Environment(\.dismiss) private var dismiss

    private static let areas: [(String, [ReadingSlot])] = [
        ("돈", [.amount, .balance]),
        ("계좌와 결제수단", [.accountName, .cardName, .institution, .accountNumber, .cardNumber]),
        ("사람과 가게", [.merchant, .payee, .memo]),
        ("때", [.time]),
        ("그 밖에", [.approvalNumber, .custom, .free]),
    ]

    private var allowed: [ReadingSlot] {
        guard let first = draft.selected.first else { return [] }
        return ReadingEntryBuilder.slots(for: draft.builder.tokens[first].kind)
    }

    var body: some View {
        SettingsPage(title: draft.selectedText) {
            ForEach(Self.areas, id: \.0) { area in
                let slots = area.1.filter(allowed.contains)
                if !slots.isEmpty {
                    SSection(title: area.0) {
                        ForEach(slots, id: \.self) { slot in
                            Button { draft.assignSelected(slot); dismiss() } label: {
                                SRow(dot: slot.tint, title: slot.title) {
                                    Circle().strokeBorder(Theme.disabled, lineWidth: 1.5).frame(width: 22, height: 22)
                                }
                            }
                            .buttonStyle(.onAllRow)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 조각 나누기

private struct SplitScreen: View {
    let draft: TeachDraft
    let token: ReadingEntryBuilder.Token
    @Environment(\.dismiss) private var dismiss
    @State private var cuts: Set<Int>

    init(draft: TeachDraft, token: ReadingEntryBuilder.Token) {
        self.draft = draft
        self.token = token
        _cuts = State(initialValue: draft.cuts)
    }

    private var characters: [Character] { Array(token.text) }

    /// 지금 고른 자리로 나눈 조각들.
    private var parts: [String] {
        var result: [String] = []
        var current = ""
        for (index, ch) in characters.enumerated() {
            if index > 0, cuts.contains(token.offset + index) { result.append(current); current = "" }
            current.append(ch)
        }
        result.append(current)
        return result
    }

    var body: some View {
        SettingsPage(title: "조각 나누기", action: ("완료", { draft.setCuts(cuts); dismiss() })) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(characters.enumerated()), id: \.offset) { index, ch in
                        if index > 0 { cutMark(at: token.offset + index) }
                        Text(String(ch)).font(.onAll(size: 22, weight: .medium)).foregroundStyle(Theme.textPrimary)
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 24)
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .padding(.horizontal, Theme.cardMargin).padding(.top, 16)
            SSection(title: "나눈 조각") {
                FlowLayout(spacing: 6) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, part in TokenChip(text: part, look: .plain) }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
        }
    }

    private func cutMark(at position: Int) -> some View {
        let on = cuts.contains(position)
        return Button {
            if on { cuts.remove(position) } else { cuts.insert(position) }
        } label: {
            Rectangle().fill(on ? Theme.accent : Theme.disabled.opacity(0.6)).frame(width: on ? 3 : 1.5, height: 30)
                .padding(.horizontal, 6).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(on ? "나눈 자리 풀기" : "여기서 나누기")
    }
}

// MARK: - 읽는 법 확인

/// 공용 표현: 고정 글자는 그대로, 칸 이름은 그 칸의 색으로.
func commonExpressionText(_ frame: String) -> Text {
    var out = AttributedString()
    for piece in ReadingEntryBuilder.pieces(of: frame) {
        switch piece {
        case let .text(value): out += AttributedString(value)
        case let .slot(name):
            var part = AttributedString(name)
            part.foregroundColor = ReadingSlot.named(name)?.tint ?? Theme.accent
            out += part
        }
    }
    return Text(out)
}

/// 이 항목이 지난 알림에서 읽는 결과: 읽혀요 N건, 읽지 못해요 N건(같은 앱에서 같은 고정 글자가 있는데 맞지 않는 알림).
struct ReadingPastCounts {
    struct Sample { let time: Int64; let signedAmount: Int64; let sub: String }
    var matched = 0
    /// 읽힌 지난 알림 중 최근 두 건: 읽은 결과를 거래처럼 보여 준다.
    var samples: [Sample] = []
    var missed: [InboxItem] = []
}

@MainActor
func countPast(model: AppModel, entry: ReadingEntry, ignoring currentID: String? = nil) async -> ReadingPastCounts {
    let items = await model.inbox()
    let parser = ReadingEntryParser(dictionary: ReadingDictionary(userEntries: [entry]))
    var literals: [String] = []
    if case let .frame(_, frame) = entry.conditions.first {
        for case let .text(value) in ReadingEntryBuilder.pieces(of: frame) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count >= 2 { literals.append(trimmed) }
        }
    }
    var counts = ReadingPastCounts()
    for item in items {
        if parser.entryID(for: item.notification) == entry.id {
            counts.matched += 1
            if counts.samples.count < 2, let sample = sample(of: item.notification, parser: parser, zone: model.dayZone.identifier) { counts.samples.append(sample) }
            continue
        }
        guard item.notification.source.applicationIdentifier == entry.applicationIdentifier, !literals.isEmpty else { continue }
        let text = NotificationText.joined(item.notification)
        if literals.allSatisfy({ text.contains($0) }) { counts.missed.append(item) }
    }
    return counts
}

@MainActor
private func sample(of notification: RawNotification, parser: ReadingEntryParser, zone: String) -> ReadingPastCounts.Sample? {
    guard let context = try? NotificationParsingContext(timeZoneIdentifier: zone, referenceTimeUnixMilliseconds: 0, parserID: "probe", parserVersion: "1"),
          case let .candidate(draft)? = try? parser.parse(notification, context: context) else { return nil }
    let who = draft.counterparty.merchantRaw ?? draft.counterparty.payeeRaw ?? draft.instrument.displayNameRaw
    let sub = [draft.kind.label, who].compactMap { $0 }.joined(separator: " · ")
    let amount = draft.amount.minorUnits
    return .init(time: draft.occurredAt.unixMilliseconds, signedAmount: draft.direction == .inflow ? amount : -amount, sub: sub)
}

private struct ReadingConfirmScreen: View {
    let draft: TeachDraft
    @State private var name = ""
    @State private var counts = ReadingPastCounts()
    @State private var showMissed = false
    @State private var entryID = UUID().uuidString

    private var zone: String { draft.model.dayZone.identifier }
    private var entry: ReadingEntry? { try? draft.entry(id: entryID) }

    var body: some View {
        SettingsPage(title: "읽는 법 확인", action: ("저장", save)) {
            SSection(title: "항목 이름") {
                TextField("예: 토스 출금 알림", text: $name).font(Theme.Typo.rowTitle)
                    .padding(.horizontal, 16).frame(minHeight: 52)
            }
            SSection(title: "공용 표현") {
                Group {
                    if let entry, case let .frame(_, frame) = entry.conditions[0] { commonExpressionText(frame) } else { Text("") }
                }
                .font(.onAll(size: 15)).foregroundStyle(Theme.textPrimary).lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 14)
            }
            SSection(title: "같은 항목으로 읽히는 지난 알림") {
                SRow(title: "읽혀요", value: "\(counts.matched)건")
                if !counts.missed.isEmpty {
                    Button { showMissed = true } label: { SRow(title: "읽지 못해요", value: "\(counts.missed.count)건", chevron: true) }
                        .buttonStyle(.onAllRow)
                }
            }
            SSection(title: "읽은 값") {
                if counts.samples.isEmpty {
                    if let kind = draft.effectiveKind { SRow(title: "종류", value: kind.label) }
                    ForEach(draft.readValues, id: \.slot) { value in SRow(title: value.slot.title, value: value.text) }
                }
                ForEach(Array(counts.samples.enumerated()), id: \.offset) { _, sample in
                    SRow(
                        title: "\(Formatting.shortDate(sample.time, zoneIdentifier: zone)) \(Formatting.time(sample.time, zoneIdentifier: zone))",
                        sub: sample.sub, value: Formatting.money(sample.signedAmount, currency: "KRW")
                    )
                }
            }
            if let message = draft.message {
                Text(message).font(Theme.Typo.label).foregroundStyle(Theme.danger).padding(.horizontal, 28).padding(.top, 12)
            }
            SButton(title: "저장하고 규칙 만들기", top: 20, run: save)
        }
        .navigationDestination(isPresented: $showMissed) { UnreadListScreen(items: counts.missed, model: draft.model) }
        .onAppear { if name.isEmpty { name = draft.name.isEmpty ? draft.defaultName() : draft.name } }
        .onChange(of: name) { draft.name = name }
        .task(id: name) {
            guard let entry else { return }
            counts = await countPast(model: draft.model, entry: entry)
        }
    }

    private func save() { Task { await draft.save() } }
}

// MARK: - 읽지 못한 알림

/// 이 항목과 모양이 비슷한데 읽지 못한 알림. 위로 돌아가 항목을 고친다.
struct UnreadListScreen: View {
    let items: [InboxItem]
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SettingsPage(title: "읽지 못한 알림 \(items.count)건") {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 8) {
                    Text(IntakeText.preview(item.notification)).font(.onAll(size: 14)).foregroundStyle(Theme.textSecondary).lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("이 항목의 모양과 달라요").font(Theme.Typo.badge).foregroundStyle(Theme.dangerStrong)
                        .padding(.horizontal, 8).frame(height: 22).background(Theme.dangerSoft, in: Capsule())
                }
                .padding(14)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .padding(.horizontal, Theme.cardMargin).padding(.top, 10)
            }
            SButton(title: "이 항목 고치기", top: 20) { dismiss() }
        }
    }
}

// MARK: - 이 알림 무시하기

struct TeachIgnoreScreen: View {
    let model: AppModel
    let notification: RawNotification
    @Environment(\.dismiss) private var dismiss
    @State private var builder: ReadingEntryBuilder
    @State private var fixed: Set<Int> = []
    @State private var name = ""
    @State private var message: String?
    @State private var counts = ReadingPastCounts()

    init(model: AppModel, notification: RawNotification) {
        self.model = model
        self.notification = notification
        _builder = State(initialValue: ReadingEntryBuilder(text: NotificationText.joined(notification)))
    }

    private var appName: String { notification.source.displayName ?? "알 수 없는 앱" }

    private var entry: ReadingEntry? {
        guard !fixed.isEmpty else { return nil }
        return try? builder.ignoreEntry(
            name: name.isEmpty ? "\(appName) 무시" : name, applicationIdentifier: notification.source.applicationIdentifier,
            fixedTokenIDs: fixed, group: appName, id: entryID
        )
    }

    @State private var entryID = UUID().uuidString

    var body: some View {
        SettingsPage(title: "이 알림 무시하기") {
            AppLine(name: appName)
            OriginalText(builder: builder, look: { fixed.contains($0.id) ? .fixed : .plain }, tap: { token in
                if fixed.contains(token.id) { fixed.remove(token.id) } else { fixed.insert(token.id) }
            })
            SSection(title: "공용 표현") {
                VStack(alignment: .leading, spacing: 6) {
                    if let entry, case let .frame(_, frame) = entry.conditions[0] { commonExpressionText(frame) } else { Text("그대로 둘 조각을 골라 주세요") }
                    Text("형태의 알림은 모두 무시돼요").foregroundStyle(Theme.textTertiary)
                }
                .font(.onAll(size: 15)).foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 14)
            }
            SSection(title: "항목 이름") {
                TextField("예: 현대카드 광고", text: $name).font(Theme.Typo.rowTitle).padding(.horizontal, 16).frame(minHeight: 52)
            }
            SSection {
                SRow(title: "무시돼요", value: "지난 알림 \(counts.matched)건")
            }
            if let message {
                Text(message).font(Theme.Typo.label).foregroundStyle(Theme.danger).padding(.horizontal, 28).padding(.top, 12)
            }
            SButton(title: "무시 항목으로 저장", top: 20, run: save)
        }
        .task(id: fixed) {
            guard let entry else { counts = ReadingPastCounts(); return }
            counts = await countPast(model: model, entry: entry)
        }
    }

    private func save() {
        guard !fixed.isEmpty else { message = "그대로 둘 조각을 하나 이상 골라 주세요."; return }
        guard let entry else { message = "항목 이름을 적어 주세요."; return }
        Task {
            var dictionary = await model.readingDictionary()
            dictionary.userEntries.append(entry)
            if await model.setReadingDictionary(dictionary) { dismiss() } else { message = "지금은 저장할 수 없어요. 잠시 뒤에 다시 해 주세요." }
        }
    }
}
