import NEOBudgetCore
import NEOBudgetInMemoryStorage
import SwiftUI

/// What the Shortcut delivered, newest first, with where each notification ended up, and the questions only the
/// user can answer: accounts the notifications mention for the first time, and which account a message that never
/// names one belongs to. Every answer replays all notifications, so earlier ones are bound too.
struct IntakeInboxView: View {
    let model: AppModel
    @State private var items: [InboxItem]?
    @State private var questions: [AccountQuestion] = []
    @State private var answering: AccountQuestion?
    @State private var choosingAccount: RuleQuestion?

    var body: some View {
        List {
            if !questions.isEmpty {
                Section {
                    ForEach(questions) { question in
                        Button { answering = question } label: { AccountQuestionRow(question: question) }
                            .foregroundStyle(.primary)
                    }
                } header: {
                    Text("이 계좌가 맞나요?")
                } footer: {
                    Text("알림에 처음 나온 계좌와 카드입니다. 답하면 이전 알림까지 다시 계산합니다.")
                }
            }
            Section {
                if let items, items.isEmpty {
                    Text("아직 받은 알림이 없습니다.").foregroundStyle(.secondary)
                }
                ForEach(items ?? []) { item in
                    InboxRow(item: item, zoneIdentifier: model.dayZone.identifier)
                        .contentShape(Rectangle())
                        .onTapGesture { Task { choosingAccount = await model.ruleQuestion(for: item.id) } }
                }
            } header: {
                Text("받은 알림")
            } footer: {
                Text("단축어의 'OnAll 알림 기록하기' 동작으로 들어온 알림입니다. '어느 계좌인지 모름'인 알림을 누르면 계좌를 정할 수 있습니다.")
            }
        }
        .navigationTitle("받은 알림")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if items == nil { ProgressView() } }
        .refreshable { await load() }
        .task(id: model.dataGeneration) { await load() }
        .sheet(item: $answering) { question in AccountAnswerSheet(model: model, question: question) }
        .sheet(item: $choosingAccount) { question in RuleAnswerSheet(model: model, question: question) }
    }

    private func load() async {
        items = await model.inbox()
        questions = await model.accountQuestions()
    }
}

private struct InboxRow: View {
    let item: InboxItem
    let zoneIdentifier: String

    var body: some View {
        let notification = item.notification
        let time = notification.notificationAtUnixMilliseconds ?? notification.capturedAtUnixMilliseconds
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(notification.source.displayName ?? "알 수 없는 앱").font(.subheadline.weight(.semibold))
                Spacer()
                Text(Formatting.shortDate(time, zoneIdentifier: zoneIdentifier) + " " + Formatting.time(time, zoneIdentifier: zoneIdentifier))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Text(IntakeText.preview(notification)).font(.footnote).lineLimit(3)
            Text(IntakeText.status(item.status))
                .font(.caption.weight(.medium))
                .foregroundStyle(IntakeText.isSettled(item.status) ? Color.secondary : Color.orange)
        }
        .padding(.vertical, 2)
    }
}

private struct AccountQuestionRow: View {
    let question: AccountQuestion

    var body: some View {
        let candidate = question.candidate
        VStack(alignment: .leading, spacing: 3) {
            Text("\(IntakeText.institution(candidate.key.institution)) \(IntakeText.kind(candidate.kind)) \(IntakeText.identifier(candidate.key.identifier))")
                .font(.subheadline.weight(.semibold))
            Text("알림 \(candidate.occurrenceCount)건").font(.caption).foregroundStyle(.secondary)
        }
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
                        Text(IntakeText.preview(example)).font(.footnote).foregroundStyle(.secondary)
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
                    Text("잔액은 0원에서 시작해 알림으로 움직인 만큼만 셉니다.")
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
            .navigationTitle("이 계좌가 맞나요?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
            .task { accounts = await model.registeredAccounts() }
            .alert("저장하지 못했습니다", isPresented: $failed) { Button("확인", role: .cancel) {} }
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
                    Text("이 앱이 보내는 같은 종류의 알림은 앞으로 고른 계좌로 기록합니다. 같은 기관에 계좌가 여러 개면 알림만으로는 정할 수 없어서 검토로 남습니다.")
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
            .navigationTitle("어느 계좌인가요?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
            .alert("정하지 못했습니다", isPresented: $failed) {
                Button("확인", role: .cancel) {}
            } message: {
                Text("같은 기관에 다른 계좌가 있으면 알림만으로는 어느 계좌인지 알 수 없습니다.")
            }
        }
    }

    private func submit(binding: ResolvedLedgerBinding?, newAccount: (name: String, kind: NewTargetKind)?) {
        Task {
            if await model.answer(question, binding: binding, newAccount: newAccount) { dismiss() } else { failed = true }
        }
    }
}
