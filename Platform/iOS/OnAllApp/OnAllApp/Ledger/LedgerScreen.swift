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
    @State private var selection = LedgerSelection()
    @State private var sheet: SelectionSheet?
    @State private var isPickingEvent = false
    @State private var openEntry: LedgerListEntry?
    @State private var isConfirmingDelete = false
    @State private var selectionNotice: String?

    enum SelectionSheet: Identifiable {
        case category, tag, settle(CalendarEventKey)
        var id: String {
            switch self {
            case .category: "category"
            case .tag: "tag"
            case let .settle(key): "settle-" + key.id
            }
        }
    }

    init(model: AppModel, mode: Mode = .spending, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
        _mode = State(initialValue: mode)
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        if selection.isActive {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text("\(selection.ids.count)건 선택").font(Theme.Typo.sheetTitle).foregroundStyle(Theme.textPrimary)
                    Text("합계 \(Formatting.money(selectedTotal, currency: "KRW"))").font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            ToolbarItem(placement: .topBarTrailing) { Button("취소") { endSelection() } }
        } else {
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
                    SettlementHubView(model: model)
                } label: {
                    Label("정산", systemImage: "arrow.left.arrow.right.circle")
                }
            }
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

    @ViewBuilder private var selectionBar: some View {
        if selection.isActive {
            let slide: AnyTransition = .move(edge: .bottom).combined(with: .opacity)
            LedgerSelectionBar(perform: perform).transition(slide)
        }
    }

    private var stack: some View {
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
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .bottom, spacing: 0) { selectionBar }
            .animation(Theme.Motion.actionBar, value: selection.isActive)
        }
    }

    private var sheeted: some View {
        stack
        .sheet(item: $sheet) { item in
            switch item {
            case .category:
                LedgerCategorySheet(count: selectedEntries.count) { category in
                    model.editMany(selectedEntries.map(\.id)) { $0.category = category }
                    sheet = nil
                    endSelection()
                }
                .onAllSelectionSheet()
            case .tag:
                LedgerTagSheet(count: selectedEntries.count, known: model.knownTags) { tags in
                    model.editMany(selectedEntries.map(\.id)) { override in
                        for tag in tags where !override.tags.contains(tag) { override.tags.append(tag) }
                    }
                    sheet = nil
                    endSelection()
                }
                .onAllSelectionSheet()
            case let .settle(key):
                SettlementSheet(model: model, eventKey: key)
            }
        }
        .sheet(item: $openEntry) { TransactionDetailView(entry: $0, model: model) }
        .fullScreenCover(isPresented: $isPickingEvent) {
            LedgerEventPicker(model: model, entries: selectedEntries, onApplied: endSelection)
        }
        .alert("\(selection.ids.count)건을 삭제할까요?", isPresented: $isConfirmingDelete) {
            Button("취소", role: .cancel) {}
            Button("삭제", role: .destructive) { deleteSelected() }
        } message: {
            Text("삭제하면 되돌릴 수 없어요.")
        }
        .alert(selectionNotice ?? "", isPresented: Binding(get: { selectionNotice != nil }, set: { if !$0 { selectionNotice = nil } })) {
            Button("확인", role: .cancel) {}
        }
        // A calendar-side edit (linking a transaction to an activity) reloads the data, and the list follows it.
        .task(id: [model.dataGeneration, model.overrideRevision]) { await load() }
    }

    var body: some View {
        sheeted
        .alert("정산으로 합칠까요?", isPresented: Binding(get: { merging != nil }, set: { if !$0 { merging = nil } })) {
            TextField("보낸 사람", text: $senderName)
            Button("합치기") { if let merging { Task { await merge(merging.deposit, onto: merging.purchase) } } }
            Button("취소", role: .cancel) {}
        } message: {
            Text(mergeQuestion)
        }
        .alert("합치지 못했어요", isPresented: Binding(get: { mergeMessage != nil }, set: { if !$0 { mergeMessage = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(mergeMessage ?? "")
        }
    }

    private var mergeQuestion: String {
        guard let merging else { return "" }
        let money = Formatting.money(merging.deposit.amount.minorUnits, currency: merging.deposit.amount.currency)
        let title = merging.purchase.transaction.title ?? "이 지출"
        return "\(money)을 \(title)에서 돌려받은 돈으로 기록해요. 통장 내역은 그대로예요."
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
                        ForEach(Array(section.entries.enumerated()), id: \.element.id) { index, entry in
                            let joins = selection.joins(in: section.entries, at: index)
                            row(entry)
                                .padding(.horizontal, Theme.Space.s)
                                .listRowSeparator(.hidden)
                                .listRowBackground(
                                    SelectableRowBackground(isSelected: selection.contains(entry.id), joinsAbove: joins.above, joinsBelow: joins.below)
                                        .padding(.horizontal, Theme.Space.m)
                                        .background(Theme.surface)
                                )
                                .listRowInsets(EdgeInsets(top: Theme.Space.s, leading: Theme.Space.l, bottom: Theme.Space.s, trailing: Theme.Space.l))
                        }
                    } header: {
                        LedgerDayHeader(section: section, isToday: section.day == today, netted: nettedByDay[section.day] ?? [:])
                    }
                }
            }
            // One continuous scroll: plain sections whose day header stays pinned until the next day pushes it away.
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.surface)
        }
    }

    /// A transaction row: opens its details, or in selection mode adds/removes it. A long press starts selection with it picked.
    @ViewBuilder
    private func row(_ entry: LedgerListEntry) -> some View {
        let label = LedgerRow(entry: entry, zoneIdentifier: model.dayZone.identifier)
        if selection.isActive {
            Button { withAnimation(Theme.Motion.select) { selection.toggle(entry.id) } } label: { label.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection.contains(entry.id) ? .isSelected : [])
        } else {
            Button { openEntry = entry } label: { label.contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .simultaneousGesture(LongPressGesture(minimumDuration: Theme.Motion.longPressSeconds).onEnded { _ in
                Haptics.enterEdit()
                withAnimation(Theme.Motion.select) { selection.begin(with: entry.id) }
            })
            .dropDestination(for: String.self) { items, _ in
                guard let id = items.first, let deposit = deposits.first(where: { $0.id.rawValue == id }) else { return false }
                senderName = deposit.title ?? ""
                merging = (deposit, entry)
                return true
            }
        }
    }

    private var selectedEntries: [LedgerListEntry] { (sections ?? []).flatMap(\.entries).filter { selection.contains($0.id) } }

    private var selectedTotal: Int64 { selectedEntries.reduce(0) { $0 + $1.signedNetMinorUnits } }

    private func endSelection() { withAnimation(Theme.Motion.select) { selection.end() } }

    private func perform(_ action: LedgerSelectionBar.Action) {
        switch action {
        case .category: sheet = .category
        case .tag: sheet = .tag
        case .event: isPickingEvent = true
        case .delete: confirmDelete()
        case .settle: Task { await settleSelected() }
        }
    }

    /// Only typed-in transactions can be deleted; what the bank or card reported stays (`TransactionEditSheet` says the same for one row).
    private func confirmDelete() {
        let manual = selectedEntries.filter { $0.transaction.id.rawValue.hasPrefix(ManualTransaction.idPrefix) }
        if manual.isEmpty {
            selectionNotice = "카드·통장에서 온 거래는 지울 수 없어요."
        } else if manual.count < selectedEntries.count {
            selectionNotice = "카드·통장에서 온 거래는 지울 수 없어요. 직접 입력한 거래만 골라서 지워 주세요."
        } else {
            isConfirmingDelete = true
        }
    }

    private func deleteSelected() {
        model.removeManuals(Set(selectedEntries.map(\.id)))
        endSelection()
    }

    /// Settling is done per event (the settlement sheet splits an event's linked spending), so it opens for the one event every picked
    /// transaction is in. Mixed or unlinked picks are asked to be put in an event first.
    private func settleSelected() async {
        let activities = Set(selectedEntries.flatMap { $0.portions.compactMap(\.activityID) })
        let everyOneLinked = selectedEntries.allSatisfy { entry in entry.portions.contains { $0.activityID != nil } }
        guard everyOneLinked, activities.count == 1, let activity = activities.first, let first = selectedEntries.first else {
            selectionNotice = "같은 일정에 들어 있는 거래만 정산할 수 있어요. 먼저 '일정'에서 한 일정으로 모아 주세요."
            return
        }
        let day = model.dayZone.localDate(of: first.transaction.occurredAtUnixMilliseconds)
        let timelines = await model.readDays((-3...3).map { day.adding(days: $0) }).compactMap(\.timeline)
        let block = timelines.flatMap(\.blocks).first { $0.activity?.activityID == activity }
        guard let block else {
            selectionNotice = "이 일정을 찾지 못했어요. 일정에서 정산해 주세요."
            return
        }
        sheet = .settle(block.eventKey)
    }

    private var nettedByDay: [LocalDate: [String: Int64]] { NettedSpendingTotals.byDay(model.nettedSpending, zone: model.dayZone) }

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
    var netted: [String: Int64] = [:]

    var body: some View {
        let totals = NettedSpendingTotals.adding(netted, to: section.totals)
        HStack(alignment: .center, spacing: Theme.Space.s) {
            Text(Formatting.dayTitle(section.day)).font(.system(.subheadline, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            if isToday { StatusBadge(text: "오늘", tone: .accent) }
            Spacer()
            // A day whose refunds outweigh its spending got money back: "+3,000원" in blue, not "-3,000원".
            let isMoneyBack = !totals.isEmpty && totals.allSatisfy { $0.minorUnits < 0 }
            Text(totals.map { ($0.minorUnits < 0 ? "+" : "") + Formatting.money(abs($0.minorUnits), currency: $0.currency) }.joined(separator: " · "))
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
                HStack(spacing: Theme.Space.xs) {
                    Text(transaction.title ?? "거래").font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    if entry.isWaitingForSettlement { StatusBadge(text: "정산 대기 중", tone: .caution) }
                }
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
        case let .pending(from): return from + " 정산 대기 중 " + Formatting.money(offset.minorUnits, currency: currency)
        case let .surplus(from): what = from + " 더 보낸 돈"
        }
        return what + " " + Formatting.money(offset.minorUnits, currency: currency) + " · " + Formatting.shortDate(offset.occurredAtUnixMilliseconds, zoneIdentifier: zoneIdentifier)
    }

    private var subtitle: String {
        var parts = [Formatting.time(entry.transaction.occurredAtUnixMilliseconds, zoneIdentifier: zoneIdentifier)]
        if entry.transaction.flow == .refund { parts.append("환불") }
        if entry.transaction.id.rawValue.hasPrefix(ManualTransaction.idPrefix) { parts.append("직접 입력") }
        parts.append(contentsOf: entry.activityTitles)
        parts.append(contentsOf: entry.tags.map { "#" + $0 })
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
