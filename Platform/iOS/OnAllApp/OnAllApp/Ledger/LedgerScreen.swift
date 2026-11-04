import Foundation
import NEOBudgetCalendar
import NEOBudgetCore
import SwiftUI

/// The ledger, opened from the calendar's list / calendar switch, in two readings of the same ledger:
/// - **목록**: every spend and refund, newest day first, one white card per day, a day's activities as tinted boxes in it. Tapping a row opens its details;
///   a long press starts selection mode. Recent deposits nothing explains yet sit on top; dragging one onto a purchase records it as that
///   purchase's settlement (`DepositMerge`).
/// - **계좌·카드**: what really moved on each account and card, unnetted, to compare with the bank, and each card's usage this month.
struct LedgerScreen: View {
    enum Mode: Hashable { case spending, accounts }

    private enum Destination: Hashable { case settlement, people, inbox }

    let model: AppModel
    let onClose: () -> Void
    @State private var mode: Mode
    @State private var sections: [LedgerDaySection]?
    @State private var deposits: [LedgerDeposit] = []
    /// What others still owe the user, in KRW; the 정산 chip under the title.
    @State private var receivable: Int64 = 0
    /// A deposit dropped on a purchase, waiting for the user to confirm who sent it.
    @State private var merging: (deposit: LedgerDeposit, purchase: LedgerListEntry)?
    @State private var senderName = ""
    @State private var mergeMessage: String?
    @State private var selection = LedgerSelection()
    @State private var sheet: SelectionSheet?
    @State private var isPickingEvent = false
    @State private var openEntry: LedgerListEntry?
    @State private var isConfirmingDelete = false
    @State private var isAdding = false
    @State private var destination: Destination?
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

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 0) {
                if selection.isActive {
                    Text("\(selection.ids.count)건 선택").font(Theme.Typo.h1).tracking(-0.5).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Button("취소") { endSelection() }
                        .font(Font.onAll(size: 15, weight: .medium)).foregroundStyle(Theme.textSecondary)
                        .frame(minHeight: Theme.hitTarget).contentShape(Rectangle())
                } else {
                    Text(mode == .spending ? "가계부" : "계좌·카드").font(Theme.Typo.h1).tracking(-0.5).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Spacer()
                    viewSwitch.padding(.trailing, 6)
                    menu
                    Button { isAdding = true } label: { icon("plus") }.accessibilityLabel("내역 추가")
                }
            }
            .padding(.leading, 24).padding(.trailing, selection.isActive ? 24 : 14).padding(.top, 8)
            if selection.isActive {
                Text("합계 \(selectedTotalText)").font(Theme.Typo.label).foregroundStyle(Theme.textTertiary).padding(.horizontal, 24)
            } else if mode == .spending, receivable > 0 {
                Button { destination = .settlement } label: {
                    Text("정산 받을 돈 \(Formatting.money(receivable, currency: "KRW")) ›").font(Theme.Typo.chip).foregroundStyle(Theme.accentStrong)
                        .padding(.horizontal, Theme.Space.m).frame(height: Theme.chipHeight)
                        .background(Theme.accentSoft, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24).padding(.top, 2)
            }
        }
    }

    /// The design's list / calendar switch: the list half is on here; the calendar half goes back.
    private var viewSwitch: some View {
        HStack(spacing: 0) {
            switchHalf("list", on: true) {}
            switchHalf("cal", on: false, action: onClose)
        }
        .padding(2).background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.segment, style: .continuous))
    }

    private func switchHalf(_ name: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            LineIcon(name: name, size: 20)
                .foregroundStyle(on ? Theme.accentStrong : Theme.textTertiary)
                .frame(width: 36, height: Theme.segmentHeight)
                .background(on ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name == "list" ? "목록" : "캘린더")
    }

    private var menu: some View {
        Menu {
            Button(mode == .spending ? "계좌·카드" : "가계부 목록") { mode = mode == .spending ? .accounts : .spending }
            Button("정산") { destination = .settlement }
            Button("사람") { destination = .people }
            if !model.isDemo { Button("받은 알림") { destination = .inbox } }
        } label: { icon("dots") }
        .accessibilityLabel("더 보기")
    }

    private func icon(_ name: String) -> some View {
        LineIcon(name: name).foregroundStyle(Theme.textPrimary).frame(width: Theme.hitTarget, height: Theme.hitTarget).contentShape(Rectangle())
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Theme.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    header
                    switch mode {
                    case .spending: content.refreshable { await load() }
                    case .accounts: AccountsView(model: model)
                    }
                }
                if selection.isActive {
                    LedgerSelectionBar(perform: perform).transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if isConfirmingDelete {
                    LedgerDeleteAlert(count: selection.ids.count, cancel: { isConfirmingDelete = false }, confirm: { isConfirmingDelete = false; deleteSelected() })
                        .transition(.opacity)
                }
            }
            .animation(Theme.Motion.actionBar, value: selection.isActive)
            .animation(Theme.Motion.scrim, value: isConfirmingDelete)
            .tint(Theme.accent)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $destination) { target in
                switch target {
                case .settlement: SettlementHubView(model: model)
                case .people: PeopleListView(model: model)
                case .inbox: IntakeInboxView(model: model)
                }
            }
        }
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
        .sheet(isPresented: $isAdding) { ManualTransactionSheet(model: model) }
        .fullScreenCover(isPresented: $isPickingEvent) {
            LedgerEventPicker(model: model, entries: selectedEntries, onApplied: endSelection)
        }
        .alert(selectionNotice ?? "", isPresented: Binding(get: { selectionNotice != nil }, set: { if !$0 { selectionNotice = nil } })) {
            Button("확인", role: .cancel) {}
        }
        // A calendar-side edit (linking a transaction to an activity) reloads the data, and the list follows it.
        .task(id: [model.dataGeneration, model.overrideRevision]) { await load() }
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
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .some(sections) where sections.isEmpty:
            Text("아직 거래가 없어요").font(Theme.Typo.label).foregroundStyle(Theme.textTertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .some(sections):
            ScrollView {
                LazyVStack(spacing: Theme.Space.m) {
                    if !deposits.isEmpty { depositsCard }
                    ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                        LedgerDayCard(
                            section: section, title: dayTitle(section.day, previous: index > 0 ? sections[index - 1].day : nil),
                            isToday: section.day == today, netted: nettedByDay[section.day] ?? [:],
                            zoneIdentifier: model.dayZone.identifier, selection: selection
                        ) { entry, context in
                            row(entry, context)
                        }
                    }
                }
                .padding(.horizontal, Theme.cardMargin).padding(.top, Theme.Space.m)
                .padding(.bottom, selection.isActive ? 96 : Theme.Space.l)
            }
        }
    }

    private var depositsCard: some View {
        VStack(spacing: 0) {
            Text("정리할 입금").font(Theme.Typo.section).foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 28).padding(.top, 14).padding(.bottom, Theme.Space.xs)
            ForEach(deposits) { deposit in
                DepositRow(deposit: deposit, zoneIdentifier: model.dayZone.identifier).draggable(deposit.id.rawValue)
            }
        }
        .padding(.bottom, Theme.Space.s)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    /// "3일 화요일"; the month goes in front of the first (newest) day of each month shown, since the list runs across months.
    private func dayTitle(_ day: LocalDate, previous: LocalDate?) -> String {
        let base = "\(day.day)일 \(Formatting.weekdayShort(day))요일"
        guard let previous, previous.month == day.month, previous.year == day.year else { return "\(day.month)월 " + base }
        return base
    }

    /// A transaction row: opens its details, or in selection mode adds/removes it. A long press starts selection with it picked.
    @ViewBuilder
    private func row(_ entry: LedgerListEntry, _ context: LedgerRowContext) -> some View {
        let isSelected = selection.contains(entry.id)
        let label = LedgerRow(entry: entry, zoneIdentifier: model.dayZone.identifier, context: context, isSelected: isSelected)
        if selection.isActive {
            Button { withAnimation(Theme.Motion.select) { selection.toggle(entry.id) } } label: { label }
                .buttonStyle(LedgerRowPressStyle())
                .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            Button { openEntry = entry } label: { label.contentShape(Rectangle()) }
            .buttonStyle(LedgerRowPressStyle())
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

    // MARK: Selection

    private var selectedEntries: [LedgerListEntry] { (sections ?? []).flatMap(\.entries).filter { selection.contains($0.id) } }

    private var selectedTotal: Int64 { selectedEntries.reduce(0) { $0 + $1.signedNetMinorUnits } }

    private var selectedTotalText: String {
        let total = selectedTotal
        return (total > 0 ? "−" : total < 0 ? "+" : "") + Formatting.money(abs(total), currency: "KRW")
    }

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

    // MARK: Data

    private var nettedByDay: [LocalDate: [String: Int64]] { NettedSpendingTotals.byDay(model.nettedSpending, zone: model.dayZone) }

    private var today: LocalDate { model.dayZone.localDate(of: Int64(Date().timeIntervalSince1970 * 1_000)) }

    private func load() async {
        if let loaded = await model.ledgerSections() { sections = loaded } else if sections == nil { sections = [] }
        deposits = await model.unclassifiedDeposits(since: model.nowMilliseconds - Self.depositWindowMilliseconds)
        if let life = await model.lifeState() {
            let summaries = life.settlementSummaries(nowUnixMilliseconds: model.nowMilliseconds + model.displayClockOffsetMilliseconds, overdueAfterDays: 14)
            receivable = summaries.filter { $0.currency == "KRW" }.reduce(0) { $0 + $1.receivableMinorUnits }
        }
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
