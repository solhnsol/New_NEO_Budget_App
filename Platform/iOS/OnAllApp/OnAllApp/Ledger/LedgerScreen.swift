import Foundation
import NEOBudgetCalendar
import NEOBudgetCore
import SwiftUI

/// The ledger, opened from the calendar's menu, in two readings of the same ledger:
/// - **목록**: every spend and refund as a plain list, newest day first, as the timeline shows them. No grid; tapping a row opens its details.
///   Recent deposits nothing explains yet sit on top; dragging one onto a purchase records it as that purchase's settlement (`DepositMerge`).
/// - **계좌·카드**: what really moved on each account and card, unnetted, to compare with the bank, and each card's usage this month.
struct LedgerScreen: View {
    enum Mode: Hashable { case spending, accounts }

    let model: AppModel
    let onClose: () -> Void
    @State private var mode: Mode
    @State private var sections: [LedgerDaySection]?
    @State private var deposits: [LedgerDeposit] = []
    /// A deposit dropped on a purchase, waiting for the user to confirm who sent it.
    @State private var merging: (deposit: LedgerDeposit, purchase: LedgerListEntry)?
    @State private var senderName = ""
    @State private var mergeMessage: String?

    init(model: AppModel, mode: Mode = .spending, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
        _mode = State(initialValue: mode)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .spending: content.refreshable { await load() }
                case .accounts: AccountsView(model: model)
                }
            }
            .tint(Theme.accent)
            .navigationTitle("가계부")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("보기", selection: $mode) {
                        Text("목록").tag(Mode.spending)
                        Text("계좌·카드").tag(Mode.accounts)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                }
                ToolbarItem(placement: .topBarLeading) { Button("닫기", action: onClose) }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        PeopleListView(model: model)
                    } label: {
                        Label("사람", systemImage: "person.2")
                    }
                }
                if !model.isDemo {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            IntakeInboxView(model: model)
                        } label: {
                            Label("받은 알림", systemImage: "tray")
                        }
                    }
                }
            }
        }
        // A calendar-side edit (linking a transaction to an activity) reloads the data, and the list follows it.
        .task(id: [model.dataGeneration, model.overrideRevision]) { await load() }
        .alert("정산으로 합칠까요?", isPresented: Binding(get: { merging != nil }, set: { if !$0 { merging = nil } })) {
            TextField("보낸 사람", text: $senderName)
            Button("합치기") { if let merging { Task { await merge(merging.deposit, onto: merging.purchase) } } }
            Button("취소", role: .cancel) {}
        } message: {
            if let merging {
                Text("\(Formatting.money(merging.deposit.amount.minorUnits, currency: merging.deposit.amount.currency))을 "
                     + "\(merging.purchase.transaction.title ?? "이 지출")에서 돌려받은 돈으로 기록해요. 통장 내역은 그대로예요.")
            }
        }
        .alert("합치지 못했어요", isPresented: Binding(get: { mergeMessage != nil }, set: { if !$0 { mergeMessage = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(mergeMessage ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch sections {
        case .none:
            ProgressView("거래를 불러오고 있어요").frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .some(sections) where sections.isEmpty:
            ContentUnavailableView("아직 거래가 없어요", systemImage: "wonsign.circle", description: Text("결제 알림이 오면 여기에 차곡차곡 쌓여요."))
        case let .some(sections):
            List {
                if !deposits.isEmpty {
                    Section {
                        ForEach(deposits) { deposit in
                            DepositRow(deposit: deposit, zoneIdentifier: model.dayZone.identifier)
                                .draggable(deposit.id.rawValue)
                                .listRowSeparator(.hidden)
                                .listRowBackground(Theme.surface)
                                .listRowInsets(EdgeInsets(top: Theme.Space.s, leading: Theme.Space.xl, bottom: Theme.Space.s, trailing: Theme.Space.l))
                        }
                        // A row, not a footer: a list footer is drawn on the system background and leaves black bands around it in dark mode.
                        Text("정산받은 돈이면 길게 눌러 그 지출 위에 놓아 주세요.").font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary)
                            .listRowSeparator(.hidden).listRowBackground(Theme.surface)
                            .listRowInsets(EdgeInsets(top: 0, leading: Theme.Space.xl, bottom: Theme.Space.m, trailing: Theme.Space.l))
                    } header: {
                        Text("정리할 입금").font(.system(.subheadline, weight: .semibold)).foregroundStyle(Theme.textSecondary).textCase(nil)
                    }
                }
                ForEach(sections) { section in
                    Section {
                        ForEach(section.entries) { entry in
                            NavigationLink {
                                TransactionDetailView(entry: entry, model: model)
                            } label: {
                                LedgerRow(entry: entry, zoneIdentifier: model.dayZone.identifier)
                            }
                            .dropDestination(for: String.self) { items, _ in
                                guard let id = items.first, let deposit = deposits.first(where: { $0.id.rawValue == id }) else { return false }
                                senderName = deposit.title ?? ""
                                merging = (deposit, entry)
                                return true
                            }
                            .listRowSeparator(.hidden)
                            .listRowBackground(Theme.surface)
                            .listRowInsets(EdgeInsets(top: Theme.Space.s, leading: Theme.Space.xl, bottom: Theme.Space.s, trailing: Theme.Space.l))
                        }
                    } header: {
                        LedgerDayHeader(section: section, isToday: section.day == today)
                    }
                }
            }
            // One continuous scroll: plain sections whose day header stays pinned until the next day pushes it away.
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.surface)
        }
    }

    private var today: LocalDate { model.dayZone.localDate(of: Int64(Date().timeIntervalSince1970 * 1_000)) }

    private func load() async {
        if let loaded = await model.ledgerSections() { sections = loaded } else if sections == nil { sections = [] }
        deposits = await model.unclassifiedDeposits(since: model.nowMilliseconds - Self.depositWindowMilliseconds)
    }

    /// How far back deposits are offered: a settlement usually comes within days, and older income (a salary) would only crowd the list.
    private static let depositWindowMilliseconds: Int64 = 30 * 24 * 60 * 60 * 1_000

    private func merge(_ deposit: LedgerDeposit, onto purchase: LedgerListEntry) async {
        merging = nil
        guard let name = ActivityEditing.cleanName(senderName) else { mergeMessage = "보낸 사람 이름을 넣어 주세요."; return }
        guard let life = await model.lifeState() else { mergeMessage = "아직 일정 정보를 불러오지 못했어요."; return }
        switch DepositMerge.plan(deposit, onto: purchase, senderName: name, life: life) {
        case let .failure(refusal):
            mergeMessage = Self.message(refusal, currency: deposit.amount.currency)
        case let .success(plan):
            if !(await model.merge(plan)) { mergeMessage = "저장하지 못했어요. 다시 시도해 주세요." }
        }
    }

    static func message(_ refusal: DepositMerge.Refusal, currency: String) -> String {
        switch refusal {
        case .notAPurchase: "입금은 지출 위에만 놓을 수 있어요."
        case .currencyDiffers: "통화가 다른 거래끼리는 합칠 수 없어요."
        case let .moreThanLeft(left):
            "입금이 이 지출의 남은 금액(\(Formatting.money(left, currency: currency)))보다 커요. 여러 지출을 한 번에 갚은 돈이면 일정의 정산 화면에서 나눠 주세요."
        }
    }
}

/// The boundary between two days: the date (and "오늘"), then the day's net spending, on a bar that stays at the top while its day scrolls.
struct LedgerDayHeader: View {
    let section: LedgerDaySection
    let isToday: Bool

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.s) {
            Text(Formatting.dayTitle(section.day)).font(.system(.subheadline, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            if isToday { StatusBadge(text: "오늘", tone: .accent) }
            Spacer()
            // A day whose refunds outweigh its spending got money back: "+3,000원" in blue, not "-3,000원".
            let isMoneyBack = !section.totals.isEmpty && section.totals.allSatisfy { $0.minorUnits < 0 }
            Text(section.totals.map { ($0.minorUnits < 0 ? "+" : "") + Formatting.money(abs($0.minorUnits), currency: $0.currency) }.joined(separator: " · "))
                .font(.system(.subheadline, weight: .medium)).monospacedDigit().foregroundStyle(isMoneyBack ? Theme.accent : Theme.textTertiary)
        }
        .textCase(nil)
        .padding(.top, Theme.Space.m)
        .padding(.bottom, Theme.Space.xs)
    }
}

/// One transaction line: its category on a tile, what and when (and which activities), the amount on the right; a refund is blue with a plus, as
/// Korean banks show money coming back. A purchase that got money back shows what it cost after that, the charged amount struck through under
/// it, and one small line per refund or settlement.
struct LedgerRow: View {
    let entry: LedgerListEntry
    let zoneIdentifier: String

    var body: some View {
        let transaction = entry.transaction
        let isRefund = transaction.flow == .refund
        HStack(spacing: Theme.Space.m) {
            IconTile(
                systemName: CategoryIcon.symbol(for: entry.categoryID) ?? (isRefund ? "arrow.uturn.backward" : "creditcard"),
                tint: isRefund ? Theme.accent : Theme.textSecondary
            )
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(transaction.title ?? "거래").font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(subtitle).font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                ForEach(entry.offsets) { offset in
                    Text(LedgerRow.offsetLine(offset, currency: transaction.amount.currency, zoneIdentifier: zoneIdentifier))
                        .font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
            }
            Spacer(minLength: Theme.Space.s)
            VStack(alignment: .trailing, spacing: Theme.Space.xxs) {
                Text((isRefund ? "+" : "") + Formatting.money(entry.netMinorUnits ?? transaction.amount.minorUnits, currency: transaction.amount.currency))
                    .font(Theme.Typo.amount)
                    .foregroundStyle(Theme.amountColor(isIncoming: isRefund))
                if entry.netMinorUnits != nil {
                    Text(Formatting.money(transaction.amount.minorUnits, currency: transaction.amount.currency))
                        .font(Theme.Typo.caption).monospacedDigit().strikethrough().foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    /// "환불 19,000 · 10/9" or "민수 정산 30,000 · 10/9".
    static func offsetLine(_ offset: LedgerListEntry.Offset, currency: String, zoneIdentifier: String) -> String {
        let what: String
        switch offset.kind {
        case .refund: what = "환불"
        case let .settlement(from): what = from + " 정산"
        }
        return what + " " + Formatting.money(offset.minorUnits, currency: currency) + " · " + Formatting.shortDate(offset.occurredAtUnixMilliseconds, zoneIdentifier: zoneIdentifier)
    }

    private var subtitle: String {
        var parts = [Formatting.time(entry.transaction.occurredAtUnixMilliseconds, zoneIdentifier: zoneIdentifier)]
        if entry.transaction.flow == .refund { parts.append("환불") }
        if entry.transaction.id.rawValue.hasPrefix(ManualTransaction.idPrefix) { parts.append("직접 입력") }
        parts.append(contentsOf: entry.activityTitles)
        parts.append(contentsOf: (entry.override?.tags ?? []).map { "#" + $0 })
        return parts.joined(separator: " · ")
    }
}

/// A deposit nothing explains yet: who sent it and when, the amount in blue with a plus.
struct DepositRow: View {
    let deposit: LedgerDeposit
    let zoneIdentifier: String

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            IconTile(systemName: "arrow.down.left", tint: Theme.accent)
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(deposit.title ?? "입금").font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(Formatting.shortDate(deposit.occurredAtUnixMilliseconds, zoneIdentifier: zoneIdentifier) + " "
                     + Formatting.time(deposit.occurredAtUnixMilliseconds, zoneIdentifier: zoneIdentifier) + " · 미분류 입금")
                    .font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            Spacer(minLength: Theme.Space.s)
            Text("+" + Formatting.money(deposit.amount.minorUnits, currency: deposit.amount.currency))
                .font(Theme.Typo.amount)
                .foregroundStyle(Theme.amountColor(isIncoming: true))
        }
    }
}
