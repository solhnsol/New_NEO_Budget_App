import NEOBudgetCore
import NEOBudgetInMemoryStorage
import SwiftUI

/// What the Shortcut delivered, newest first, with where each notification ended up, and the questions only the
/// user can answer: accounts the notifications mention for the first time, and which account a message that never
/// names one belongs to. Every answer replays all notifications, so earlier ones are bound too.
struct IntakeInboxView: View {
    let model: AppModel
    @State private var items: [InboxItem]?
    @State private var imported: [PendingImport] = []
    @State private var questions: [AccountQuestion] = []
    @State private var ignoredTypes: [IgnoredType] = []
    @State private var answering: AccountQuestion?
    @State private var filter = 0

    private var shown: [InboxItem] {
        (items ?? []).filter {
            switch filter {
            case 1: Self.bucket($0.status) == .recorded
            case 2: Self.bucket($0.status) == .needsCheck
            case 3: Self.bucket($0.status) == .ignored
            default: true
            }
        }
    }

    enum Bucket { case recorded, needsCheck, ignored }

    static func bucket(_ status: IntakeStatus) -> Bucket {
        switch status {
        case .recorded, .sameActAs, .coveredByImport: .recorded
        case .notTransaction, .ignoredByUser: .ignored
        case .waiting, .unreadable, .failed: .needsCheck
        }
    }

    var body: some View {
        let all = items ?? []
        let titles = ["전체 \(all.count)", "기록됨", "확인 필요 \(all.filter { Self.bucket($0.status) == .needsCheck }.count)", "무시"]
        SettingsPage(title: "받은 알림 내역") {
            SChipRow(titles: titles, selection: $filter)
            if !questions.isEmpty {
                SSection(title: "이 계좌가 맞나요?") {
                    ForEach(questions) { question in
                        Button { answering = question } label: { AccountQuestionRow(question: question) }.buttonStyle(.onAllRow)
                    }
                }
            }
            if !imported.isEmpty {
                SSection(title: "가져온 기록 중 정리할 것") {
                    ForEach(imported) { item in ImportedRow(item: item, zoneIdentifier: model.dayZone.identifier) }
                }
            }
            if filter == 3, !ignoredTypes.isEmpty {
                SSection(title: "무시하는 알림") {
                    ForEach(ignoredTypes) { type in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(type.appName ?? "알 수 없는 앱").font(.onAll(size: 12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                                Text(type.sample).font(.onAll(size: 14)).foregroundStyle(Theme.textSecondary).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                            Button("해제") { Task { if await model.stopIgnoring(type.key) { await load() } } }
                                .font(Theme.Typo.button).foregroundStyle(Theme.accentStrong)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12).rowDivider(inset: 16)
                    }
                }
            }
            ForEach(sections, id: \.title) { section in
                SSection(title: section.title) {
                    ForEach(section.items) { item in
                        NavigationLink { InboxDetailScreen(model: model, item: item) } label: { InboxRow(item: item, zoneIdentifier: model.dayZone.identifier) }
                            .buttonStyle(.onAllRow)
                    }
                }
            }
        }
        .task(id: model.dataGeneration) { await load() }
        .sheet(item: $answering) { question in AccountAnswerSheet(model: model, question: question) }
    }

    private var sections: [(title: String, items: [InboxItem])] {
        let zone = model.dayZone
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let today = zone.localDate(of: now), yesterday = zone.localDate(of: now - 86_400_000)
        var order: [String] = []
        var groups: [String: [InboxItem]] = [:]
        for item in shown {
            let time = item.notification.notificationAtUnixMilliseconds ?? item.notification.capturedAtUnixMilliseconds
            let day = zone.localDate(of: time)
            let title = day == today ? "오늘" : day == yesterday ? "어제" : Formatting.shortDate(time, zoneIdentifier: zone.identifier)
            if groups[title] == nil { order.append(title) }
            groups[title, default: []].append(item)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    private func load() async {
        items = await model.inbox()
        imported = await model.pendingImports()
        questions = await model.accountQuestions()
        ignoredTypes = await model.ignoredTypes()
    }
}

/// One received notification (settings-v5 `.ni`): app, time and result pill, the text in two lines, what became of it.
private struct InboxRow: View {
    let item: InboxItem
    let zoneIdentifier: String

    var body: some View {
        let notification = item.notification
        let time = notification.notificationAtUnixMilliseconds ?? notification.capturedAtUnixMilliseconds
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(notification.source.displayName ?? "알 수 없는 앱").font(.onAll(size: 12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                Text(Formatting.time(time, zoneIdentifier: zoneIdentifier)).font(.onAll(size: 12)).foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 0)
                SPill(text: pill.text, accent: pill.accent)
            }
            Text(IntakeText.preview(notification)).font(.onAll(size: 14)).foregroundStyle(Theme.textSecondary).lineSpacing(3).lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(IntakeText.status(item.status)).font(Theme.Typo.label).foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .contentShape(Rectangle())
        .rowDivider(inset: 16)
    }

    private var pill: (text: String, accent: Bool) { InboxPill.of(item.status) }
}

enum InboxPill {
    static func of(_ status: IntakeStatus) -> (text: String, accent: Bool) {
        switch IntakeInboxView.bucket(status) {
        case .recorded: ("기록됨", false)
        case .needsCheck: ("확인 필요", true)
        case .ignored: ("무시", false)
        }
    }
}

/// The small result pill (11 semibold, 22 high).
struct SPill: View {
    let text: String
    var accent = false

    var body: some View {
        Text(text).font(Theme.Typo.badge).foregroundStyle(accent ? Theme.accentStrong : Theme.textTertiary)
            .padding(.horizontal, 8).frame(height: 22)
            .background(accent ? Theme.accentSoft : Theme.fill, in: Capsule())
    }
}

/// 받은 알림: the whole text, where it ended up, and the way to the account question or a new rule.
struct InboxDetailScreen: View {
    let model: AppModel
    let item: InboxItem
    @State private var choosingAccount: RuleQuestion?
    @State private var teaching = false
    @State private var failed = false
    @Environment(\.dismiss) private var dismiss

    private func toggleIgnore(stop: Bool) {
        Task {
            let key = IgnoredType.key(of: item.notification)
            let done = stop ? await model.stopIgnoring(key) : await model.ignoreType(of: item.id)
            if done { dismiss() } else { failed = true }
        }
    }

    var body: some View {
        let notification = item.notification
        let time = notification.notificationAtUnixMilliseconds ?? notification.capturedAtUnixMilliseconds
        let zone = model.dayZone.identifier
        SettingsPage(title: "받은 알림") {
            Text("\(notification.source.displayName ?? "알 수 없는 앱") · \(Formatting.shortDate(time, zoneIdentifier: zone)) \(Formatting.time(time, zoneIdentifier: zone))")
                .font(Theme.Typo.label).foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 4)
            Text(IntakeText.preview(notification)).font(.onAll(size: 14)).foregroundStyle(Theme.textSecondary).lineSpacing(5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(Theme.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 16).padding(.top, 6)
            SSection(title: "처리 결과") {
                SRow(icon: "tag", tone: IntakeText.isSettled(item.status) ? .green : .orange, title: IntakeText.status(item.status))
            }
            if IntakeText.asksForAccount(item.status) {
                SButton(title: "계좌 정하기", light: true) { Task { choosingAccount = await model.ruleQuestion(for: item.id) } }
            }
            SButton(title: "이 알림 읽는 법 알려주기", top: 10) { teaching = true }
            if case .ignoredByUser = item.status {
                SButton(title: "이 유형 알림 다시 받기", light: true, top: 10) { toggleIgnore(stop: true) }
            } else {
                SButton(title: "이 유형 알림 무시하기", light: true, top: 10) { toggleIgnore(stop: false) }
            }
        }
        .sheet(item: $choosingAccount) { question in RuleAnswerSheet(model: model, question: question) }
        .alert("바꾸지 못했어요", isPresented: $failed) { Button("확인", role: .cancel) {} }
        .navigationDestination(isPresented: $teaching) { TeachReadingScreen(model: model, notification: notification) }
    }
}

private struct ImportedRow: View {
    let item: PendingImport
    let zoneIdentifier: String

    var body: some View {
        SRow(
            title: item.title ?? "이름 없는 거래",
            sub: Formatting.shortDate(item.occurredAtUnixMilliseconds, zoneIdentifier: zoneIdentifier) + " · " + item.accountName,
            value: Formatting.money(item.signedMinorUnits == 0 ? item.amount.minorUnits : item.signedMinorUnits, currency: item.amount.currency)
        )
    }
}

private struct AccountQuestionRow: View {
    let question: AccountQuestion

    var body: some View {
        let candidate = question.candidate
        SRow(
            title: "\(IntakeText.institution(candidate.key.institution)) \(IntakeText.kind(candidate.kind)) \(IntakeText.identifier(candidate.key.identifier))",
            sub: "알림 \(candidate.occurrenceCount)건", chevron: true
        )
    }
}

/// "Is this one of yours?" for an account or card a notification named that the app has not seen before.
private struct AccountAnswerSheet: View {
    let model: AppModel
    let question: AccountQuestion
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var accounts: [AccountProfile] = []
    @State private var failed = false

    init(model: AppModel, question: AccountQuestion) {
        self.model = model
        self.question = question
        _name = State(initialValue: IntakeText.suggestedName(institution: question.candidate.key.institution, kind: question.candidate.kind))
    }

    var body: some View {
        let candidate = question.candidate
        NavigationStack {
            Form {
                Section {
                    LabeledContent("기관", value: IntakeText.institution(candidate.key.institution))
                    LabeledContent("종류", value: IntakeText.kind(candidate.kind))
                    LabeledContent("알림에 나온 번호", value: IntakeText.identifier(candidate.key.identifier))
                    LabeledContent("알림", value: "\(candidate.occurrenceCount)건")
                    if let example = question.example {
                        Text(IntakeText.preview(example)).font(.footnote).foregroundStyle(Theme.textSecondary)
                    }
                }
                Section {
                    TextField("이름", text: $name)
                    Button("새 계좌로 등록") {
                        guard let kind = IntakeText.newTargetKind(for: candidate.kind) else { return }
                        submit(.newAccount(name: name.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind))
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: {
                    Text("새 계좌")
                } footer: {
                    Text("잔액은 0원에서 시작해서 알림으로 움직인 만큼만 세요.")
                }
                let fitting = accounts.filter { IntakeText.fits($0, candidate.kind) }
                if !fitting.isEmpty {
                    Section("이미 등록한 계좌예요") {
                        ForEach(fitting, id: \.binding) { profile in
                            Button(profile.displayName) { submit(.existing(profile.binding)) }
                        }
                    }
                }
                Section {
                    Button("내 계좌가 아니에요", role: .destructive) { submit(.notMine) }
                }
            }
            .onAllGroupedScreen()
            .navigationTitle("이 계좌가 맞나요?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
            .task { accounts = await model.registeredAccounts() }
            .alert("저장하지 못했어요", isPresented: $failed) { Button("확인", role: .cancel) {} }
        }
    }

    private func submit(_ answer: AccountAnswer) {
        Task {
            if await model.answer(question, with: answer) { dismiss() } else { failed = true }
        }
    }
}

/// "Messages like this one are about which account?" for a notification that never names its account.
private struct RuleAnswerSheet: View {
    let model: AppModel
    let question: RuleQuestion
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var failed = false

    init(model: AppModel, question: RuleQuestion) {
        self.model = model
        self.question = question
        _name = State(initialValue: IntakeText.suggestedName(institution: question.institution, kind: question.kind))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("기관", value: IntakeText.institution(question.institution))
                    LabeledContent("종류", value: IntakeText.kind(question.kind))
                } footer: {
                    Text("이 앱이 보내는 같은 종류의 알림은 앞으로 고른 계좌로 기록해요. 같은 기관에 계좌가 여러 개면 알림만으로는 정할 수 없어서 검토로 남겨요.")
                }
                if !question.choices.isEmpty {
                    Section("등록한 계좌") {
                        ForEach(question.choices, id: \.binding) { profile in
                            Button(profile.displayName) { submit(binding: profile.binding, newAccount: nil) }
                        }
                    }
                }
                Section("새 계좌") {
                    TextField("이름", text: $name)
                    Button("새 계좌로 등록") {
                        guard let kind = IntakeText.newTargetKind(for: question.kind) else { return }
                        submit(binding: nil, newAccount: (name.trimmingCharacters(in: .whitespacesAndNewlines), kind))
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAllGroupedScreen()
            .navigationTitle("어느 계좌인가요?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
            .alert("정하지 못했어요", isPresented: $failed) {
                Button("확인", role: .cancel) {}
            } message: {
                Text("같은 기관에 다른 계좌가 있으면 알림만으로는 어느 계좌인지 알 수 없어요.")
            }
        }
    }

    private func submit(binding: ResolvedLedgerBinding?, newAccount: (name: String, kind: NewTargetKind)?) {
        Task {
            if await model.answer(question, binding: binding, newAccount: newAccount) { dismiss() } else { failed = true }
        }
    }
}
