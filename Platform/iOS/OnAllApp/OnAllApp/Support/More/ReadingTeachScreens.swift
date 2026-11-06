import NEOBudgetCore
import SwiftUI

// 읽는 법 알려주기 / 무시하기 (design-v2/settings/shapes-v1.html). 받은 알림 글을 조각으로 나눠 버튼으로 보여 주고, 사용자가 조각을 골라 항목을 만든다.

/// 알림 글의 조각 버튼들. `style`이 조각마다 모양(고르지 않음, 고름, 칸이 붙음)을 정한다.
private struct TokenFlow: View {
    enum Look { case plain, picked, marked(String) }

    let builder: ReadingEntryBuilder
    let look: (ReadingEntryBuilder.Token) -> Look
    let tap: (ReadingEntryBuilder.Token) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(builder.groups, id: \.self) { ids in
                if let token = builder.tokens.first(where: { $0.id == ids[0] }) {
                    Button { tap(token) } label: { piece(token, text: ids.compactMap { id in builder.tokens.first { $0.id == id }?.text }.joined()) }
                        .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .padding(.horizontal, Theme.cardMargin).padding(.top, 12)
    }

    @ViewBuilder
    private func piece(_ token: ReadingEntryBuilder.Token, text: String) -> some View {
        let state = look(token)
        VStack(spacing: 2) {
            Text(text).font(.onAll(size: 16)).foregroundStyle(foreground(state))
                .padding(.horizontal, 8).frame(minWidth: 28, minHeight: 36)
                .background(background(state), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(border(state), lineWidth: 1.5) }
            if case let .marked(name) = state { Text(name).font(.onAll(size: 11)).foregroundStyle(Theme.accentStrong) }
        }
        .accessibilityLabel(text)
    }

    private func foreground(_ state: Look) -> Color {
        switch state {
        case .plain: Theme.textPrimary
        case .picked, .marked: Theme.accentStrong
        }
    }

    private func background(_ state: Look) -> Color {
        switch state {
        case .plain: Theme.fill
        case .picked, .marked: Theme.accentSoft
        }
    }

    private func border(_ state: Look) -> Color {
        if case .picked = state { return Theme.accent }
        return .clear
    }
}

/// 이 알림 읽는 법 알려주기: 조각을 골라 칸(금액, 통장 이름 …)을 붙이고, 종류를 정하고, 이름을 붙여 저장한다.
struct TeachReadingScreen: View {
    let model: AppModel
    let notification: RawNotification
    @Environment(\.dismiss) private var dismiss
    @State private var builder: ReadingEntryBuilder
    @State private var picked: Set<Int> = []
    @State private var assignments: [Int: ReadingSlot] = [:]
    @State private var kind: DraftEventKind = .purchase
    @State private var name = ""
    @State private var choosingSlot = false
    @State private var message: String?
    @State private var pastCount: Int?

    private static let kinds: [(DraftEventKind, String)] = [
        (.purchase, "결제"), (.withdrawal, "출금"), (.deposit, "입금"), (.cancellation, "결제 취소"), (.refund, "환불"),
        (.transferOut, "이체 보냄"), (.transferIn, "이체 받음"), (.cardBillPayment, "카드 대금"), (.walletTopUp, "충전"),
    ]

    init(model: AppModel, notification: RawNotification) {
        self.model = model
        self.notification = notification
        _builder = State(initialValue: ReadingEntryBuilder(text: NotificationText.joined(notification)))
    }

    var body: some View {
        SettingsPage(title: "읽는 법 알려주기", action: ("저장", save)) {
            Text(notification.source.displayName ?? "알 수 없는 앱").font(Theme.Typo.label).foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 28).padding(.top, 16)
            TokenFlow(builder: builder, look: look) { toggle($0) }
            if !picked.isEmpty {
                SButton(title: "칸 붙이기", light: true, top: 12) { choosingSlot = true }
            }
            SSection(title: "종류") {
                ForEach(Self.kinds, id: \.0) { item in SRadioRow(title: item.1, isOn: kind == item.0) { kind = item.0 } }
            }
            if !assignments.isEmpty {
                SSection(title: "읽은 값") {
                    ForEach(readValues, id: \.slot) { value in SRow(title: value.slot.rawValue, value: value.text) }
                }
            }
            SSection(title: "항목 이름") {
                TextField("예: 토스 출금 알림", text: $name)
                    .font(Theme.Typo.rowTitle).padding(.horizontal, 16).frame(minHeight: 52)
            }
            if let message {
                Text(message).font(Theme.Typo.label).foregroundStyle(Theme.danger).padding(.horizontal, 28).padding(.top, 12)
            } else if let pastCount {
                Text("지난 알림 \(pastCount)건이 이 항목으로 읽혀요").font(Theme.Typo.label).foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 28).padding(.top, 12)
            }
        }
        .navigationDestination(isPresented: $choosingSlot) {
            SlotPickerScreen(allowed: allowedSlots) { slot in
                for id in picked { assignments[id] = slot }
                picked = []
                choosingSlot = false
            }
        }
        .task(id: assignments) { await countPast() }
    }

    private func look(_ token: ReadingEntryBuilder.Token) -> TokenFlow.Look {
        if let slot = assignments[token.id] { return .marked(slot.rawValue) }
        return picked.contains(token.id) ? .picked : .plain
    }

    /// 숫자 조각은 `150,000`처럼 쉼표로 이어진 것까지 한 번에 고른다. 이미 칸이 붙은 조각을 누르면 칸을 뗀다.
    private func toggle(_ token: ReadingEntryBuilder.Token) {
        let ids = builder.mergedAmountTokenIDs(startingAt: token.id)
        if assignments[token.id] != nil { ids.forEach { assignments[$0] = nil }; return }
        if token.kind == .symbol, token.text != "," { return }
        if picked.contains(token.id) { ids.forEach { picked.remove($0) } } else {
            // 숫자와 글자는 한 번에 같이 붙일 수 없다.
            if let first = picked.first, builder.tokens[first].kind != token.kind { picked = [] }
            ids.forEach { picked.insert($0) }
        }
    }

    private var allowedSlots: [ReadingSlot] {
        guard let first = picked.first else { return [] }
        return ReadingEntryBuilder.slots(for: builder.tokens[first].kind)
    }

    private var readValues: [(slot: ReadingSlot, text: String)] {
        var order: [ReadingSlot] = []
        var texts: [ReadingSlot: String] = [:]
        for token in builder.tokens {
            guard let slot = assignments[token.id] else { continue }
            if !order.contains(slot) { order.append(slot) }
            texts[slot] = (texts[slot].map { $0 + (token.spaceBefore ? " " : "") } ?? "") + token.text
        }
        return order.map { ($0, texts[$0] ?? "") }
    }

    private func draftEntry() -> ReadingEntry? {
        try? builder.readEntry(
            name: name.isEmpty ? "이름 없음" : name, applicationIdentifier: notification.source.applicationIdentifier,
            kind: kind, assignments: assignments
        )
    }

    private func countPast() async {
        guard let entry = draftEntry() else { pastCount = nil; return }
        let parser = ReadingEntryParser(dictionary: ReadingDictionary(userEntries: [entry]))
        pastCount = await Task.detached(priority: .utility) { () -> Int in await model.inbox().filter { parser.entryID(for: $0.notification) == entry.id }.count }.value
    }

    private func save() {
        do {
            let entry = try builder.readEntry(
                name: name, applicationIdentifier: notification.source.applicationIdentifier, kind: kind, assignments: assignments
            )
            Task {
                var dictionary = await model.readingDictionary()
                dictionary.userEntries.append(entry)
                if await model.setReadingDictionary(dictionary) { dismiss() } else { message = "지금은 저장할 수 없어요. 잠시 뒤에 다시 해 주세요." }
            }
        } catch ReadingEntryBuilder.BuildError.needsAmount {
            message = "금액 조각을 골라 칸을 붙여 주세요."
        } catch {
            message = "항목 이름을 적어 주세요."
        }
    }
}

/// 고른 조각에 붙일 칸을 고르는 페이지: 영역별로 묶고, 고른 글자 종류에 맞는 이름만 보인다.
private struct SlotPickerScreen: View {
    let allowed: [ReadingSlot]
    let pick: (ReadingSlot) -> Void

    private static let areas: [(String, [ReadingSlot])] = [
        ("돈", [.amount, .balance]),
        ("계좌와 결제수단", [.accountName, .cardName, .institution, .accountNumber, .cardNumber]),
        ("사람과 가게", [.merchant, .payee, .memo]),
        ("그 밖", [.approvalNumber]),
    ]

    var body: some View {
        SettingsPage(title: "칸 고르기") {
            ForEach(Self.areas, id: \.0) { area in
                let slots = area.1.filter(allowed.contains)
                if !slots.isEmpty {
                    SSection(title: area.0) {
                        ForEach(slots, id: \.self) { slot in SRadioRow(title: slot.rawValue, isOn: false) { pick(slot) } }
                    }
                }
            }
        }
    }
}

/// 이 알림 무시하기: 그대로 두고 싶은 조각만 고르면 나머지는 아무 글자나 된다. 공용 표현을 보여 주고 이름을 붙여 저장한다.
struct TeachIgnoreScreen: View {
    let model: AppModel
    let notification: RawNotification
    @Environment(\.dismiss) private var dismiss
    @State private var builder: ReadingEntryBuilder
    @State private var fixed: Set<Int> = []
    @State private var name = ""
    @State private var message: String?
    @State private var pastCount: Int?

    init(model: AppModel, notification: RawNotification) {
        self.model = model
        self.notification = notification
        _builder = State(initialValue: ReadingEntryBuilder(text: NotificationText.joined(notification)))
    }

    var body: some View {
        SettingsPage(title: "이 알림 무시하기", action: ("저장", save)) {
            Text(notification.source.displayName ?? "알 수 없는 앱").font(Theme.Typo.label).foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 28).padding(.top, 16)
            TokenFlow(builder: builder, look: { fixed.contains($0.id) ? .picked : .plain }) { token in
                if fixed.contains(token.id) { fixed.remove(token.id) } else { fixed.insert(token.id) }
            }
            SSection(title: "공용 표현") {
                Text(common).font(.onAll(size: 16)).foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 14)
            }
            SSection(title: "항목 이름") {
                TextField("예: 현대카드 광고", text: $name).font(Theme.Typo.rowTitle).padding(.horizontal, 16).frame(minHeight: 52)
            }
            if let message {
                Text(message).font(Theme.Typo.label).foregroundStyle(Theme.danger).padding(.horizontal, 28).padding(.top, 12)
            } else if let pastCount {
                SRow(title: "무시돼요", value: "지난 알림 \(pastCount)건").background(Theme.surface).padding(.top, 12)
            }
            SButton(title: "무시 항목으로 저장", top: 16, run: save)
        }
        .task(id: fixed) { await countPast() }
    }

    private var common: String {
        guard let entry = try? builder.ignoreEntry(name: "x", applicationIdentifier: nil, fixedTokenIDs: fixed),
              case let .frame(_, frame) = entry.conditions[0] else { return "" }
        return ReadingEntryBuilder.commonExpression(of: frame)
    }

    private func countPast() async {
        guard !fixed.isEmpty, let entry = try? builder.ignoreEntry(
            name: "x", applicationIdentifier: notification.source.applicationIdentifier, fixedTokenIDs: fixed
        ) else { pastCount = nil; return }
        let parser = ReadingEntryParser(dictionary: ReadingDictionary(userEntries: [entry]))
        pastCount = await Task.detached(priority: .utility) { () -> Int in await model.inbox().filter { parser.entryID(for: $0.notification) == entry.id }.count }.value
    }

    private func save() {
        guard !fixed.isEmpty else { message = "그대로 둘 조각을 하나 이상 골라 주세요."; return }
        do {
            let entry = try builder.ignoreEntry(name: name, applicationIdentifier: notification.source.applicationIdentifier, fixedTokenIDs: fixed)
            Task {
                var dictionary = await model.readingDictionary()
                dictionary.userEntries.append(entry)
                if await model.setReadingDictionary(dictionary) { dismiss() } else { message = "지금은 저장할 수 없어요. 잠시 뒤에 다시 해 주세요." }
            }
        } catch {
            message = "항목 이름을 적어 주세요."
        }
    }
}
