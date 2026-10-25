import NEOBudgetCalendar
import NEOBudgetCore
import SwiftUI

/// 정산 허브 (`docs/ledger-behavior.md`, 정산 이후 결정): who still owes the user and whom the user owes, the deposits worth a question, and a way to
/// register money the user is about to send. Opened from the ledger's toolbar. It only reads; every change goes through a sheet that says what it records.
struct SettlementHubView: View {
    let model: AppModel
    @State private var life: LifeState?
    @State private var deposits: [LedgerDeposit] = []
    /// What each purchase was called, so a request reads as "마트" and not "정산".
    @State private var purchaseTitles: [LedgerEntryID: String] = [:]
    @State private var dismissed = DismissedDeposits.load()
    @State private var confirming: LedgerDeposit?
    @State private var registering = false
    @State private var showsAllQuestions = false

    /// A receivable open longer than this is marked (a marker only: no reminders in the first release).
    private static let overdueDays = 14

    var body: some View {
        List {
            if !questions.isEmpty {
                Section {
                    ForEach(showsAllQuestions ? questions : Array(questions.prefix(2))) { deposit in
                        DepositQuestionCard(deposit: deposit, senderName: senderName(of: deposit), zoneIdentifier: model.dayZone.identifier) {
                            confirming = deposit
                        } dismiss: {
                            dismissed.insert(deposit.id.rawValue)
                            DismissedDeposits.save(dismissed)
                        }
                    }
                    if questions.count > 2 && !showsAllQuestions {
                        Button("입금 \(questions.count - 2)건 더 보기") { showsAllQuestions = true }
                            .buttonStyle(.onAllSecondary).frame(maxWidth: .infinity)
                    }
                } header: {
                    Text("확인할 입금")
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: Theme.Space.xs, leading: 0, bottom: Theme.Space.xs, trailing: 0))
            }
            if summaries.isEmpty {
                Section {
                    ContentUnavailableView(
                        "정산할 돈이 없어요", systemImage: "checkmark.circle",
                        description: Text("일정에서 정산 요청을 만들거나, 곧 보낼 돈을 미리 등록하면 여기에 모여요.")
                    )
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(summaries, id: \.personID) { summary in
                        SummaryRow(
                            summary: summary, name: life?.persons[summary.personID]?.displayName ?? "알 수 없음",
                            zoneIdentifier: model.dayZone.identifier
                        )
                    }
                } header: {
                    Text("사람별 정산")
                } footer: {
                    Text("\(Self.overdueDays)일이 넘도록 못 받은 돈은 표시만 해요. 알림은 보내지 않아요.")
                }
                .onAllCardRow()
            }
        }
        .onAllGroupedScreen()
        .navigationTitle("정산")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { registering = true } label: { Label("줄 돈 등록", systemImage: "plus") }
            }
        }
        .task(id: [model.dataGeneration, model.overrideRevision]) { await load() }
        .sheet(item: $confirming) { deposit in
            if let life { DepositConfirmSheet(model: model, deposit: deposit, life: life, senderName: senderName(of: deposit), purchaseTitles: purchaseTitles) }
        }
        .sheet(isPresented: $registering) { ExpectedPaymentSheet(model: model) }
    }

    private var summaries: [PersonSettlementSummary] {
        life?.settlementSummaries(nowUnixMilliseconds: model.nowMilliseconds + model.displayClockOffsetMilliseconds, overdueAfterDays: Self.overdueDays)
            .filter { $0.receivableMinorUnits > 0 || $0.payableMinorUnits > 0 || $0.unknownOpenCount > 0 } ?? []
    }

    private var questions: [LedgerDeposit] {
        guard let life else { return [] }
        // The ones from someone who owes the user come first.
        return deposits.filter { deposit in
            guard !dismissed.contains(deposit.id.rawValue) else { return false }
            if case .askToConfirm = life.depositReview(from: sender(of: deposit)?.id, currency: deposit.amount.currency) { return true }
            return false
        }
        .sorted { (sender(of: $0) != nil ? 0 : 1) < (sender(of: $1) != nil ? 0 : 1) }
    }

    private func sender(of deposit: LedgerDeposit) -> Person? {
        guard let name = deposit.title else { return nil }
        return life?.persons.values.filter { !$0.isSelf && $0.matches(name: name) }.min { $0.id < $1.id }
    }

    private func senderName(of deposit: LedgerDeposit) -> String { sender(of: deposit)?.displayName ?? deposit.title ?? "누군가" }

    private func load() async {
        life = await model.lifeState()
        let entries = (await model.ledgerSections() ?? []).flatMap(\.entries)
        purchaseTitles = Dictionary(entries.compactMap { entry in entry.transaction.title.map { (entry.id, $0) } }, uniquingKeysWith: { first, _ in first })
        deposits = await model.unclassifiedDeposits(since: model.nowMilliseconds - 30 * 86_400_000)
    }
}

/// Deposits the user said were just money someone sent. Kept on the device; asking again would only nag.
enum DismissedDeposits {
    private static let key = "settlement.dismissedDeposits"
    static func load(defaults: UserDefaults = .standard) -> Set<String> { Set(defaults.stringArray(forKey: key) ?? []) }
    static func save(_ ids: Set<String>, defaults: UserDefaults = .standard) { defaults.set(Array(ids).sorted(), forKey: key) }
}

/// "민수님이 보낸 30,000원 — 열려 있는 정산이 맞나요?" with the two answers under it.
private struct DepositQuestionCard: View {
    let deposit: LedgerDeposit
    let senderName: String
    let zoneIdentifier: String
    let confirm: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m) {
                PersonAvatar(name: senderName, size: 40)
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text(senderName).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text(Formatting.shortDate(deposit.occurredAtUnixMilliseconds, zoneIdentifier: zoneIdentifier) + " 입금")
                        .font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: Theme.Space.s)
                Text("+" + Formatting.money(deposit.amount.minorUnits, currency: deposit.amount.currency))
                    .font(Theme.Typo.amount).foregroundStyle(Theme.amountColor(isIncoming: true))
            }
            Text("열려 있는 정산을 받은 돈이 맞나요?").font(Theme.Typo.label).foregroundStyle(Theme.textSecondary)
            HStack(spacing: Theme.Space.s) {
                Button("정산이 맞아요", action: confirm).buttonStyle(.onAllPrimaryCompact)
                Button("아니에요", action: dismiss).buttonStyle(.onAllSecondary).frame(minHeight: 44)
            }
        }
        .padding(Theme.Space.l)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

private struct SummaryRow: View {
    let summary: PersonSettlementSummary
    let name: String
    let zoneIdentifier: String

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            PersonAvatar(name: name, size: 40)
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                HStack(spacing: Theme.Space.xs) {
                    Text(name).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary)
                    if summary.isOverdue { StatusBadge(text: "14일 넘었어요", tone: .caution) }
                }
                Text(subtitle).font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: Theme.Space.s)
            VStack(alignment: .trailing, spacing: Theme.Space.xxs) {
                if summary.receivableMinorUnits > 0 {
                    Text("받을 돈 " + Formatting.money(summary.receivableMinorUnits, currency: summary.currency))
                        .font(Theme.Typo.amount).foregroundStyle(Theme.accent)
                }
                if summary.payableMinorUnits > 0 {
                    Text("줄 돈 " + Formatting.money(summary.payableMinorUnits, currency: summary.currency))
                        .font(Theme.Typo.amount).foregroundStyle(Theme.textPrimary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let oldest = summary.oldestOpenAtUnixMilliseconds { parts.append(Formatting.shortDate(oldest, zoneIdentifier: zoneIdentifier) + "부터") }
        if summary.unknownOpenCount > 0 { parts.append("금액을 모르는 정산 \(summary.unknownOpenCount)건") }
        return parts.joined(separator: " · ")
    }
}
