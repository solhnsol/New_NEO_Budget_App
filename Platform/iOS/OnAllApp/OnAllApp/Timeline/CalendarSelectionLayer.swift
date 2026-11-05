import NEOBudgetCalendar
import NEOBudgetCore
import SwiftUI

/// Selection mode on the calendar (the design's: a long press on a transaction row picks it, taps pick more, the bar below acts on all of them).
/// The picks live in `AppModel.selection`; the rows draw themselves from it. The actions are the ledger tab's: 분류 · 일정 · 태그 · 정산 · 삭제.
struct CalendarSelectionLayer: ViewModifier {
    let model: AppModel
    @State private var sheet: LedgerScreen.SelectionSheet?
    @State private var isPickingEvent = false
    @State private var pickEntries: [LedgerListEntry] = []
    @State private var confirmsDelete = false
    @State private var notice: String?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if model.selection.isActive {
                    LedgerSelectionBar(perform: perform, actions: [.category, .event, .tag, .group, .settle, .delete], ungroups: picksAreOneBundle).transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .overlay {
                if confirmsDelete {
                    LedgerDeleteAlert(count: model.selection.ids.count, cancel: { confirmsDelete = false }, confirm: { confirmsDelete = false; deleteSelected() })
                        .transition(.opacity)
                }
            }
            .animation(Theme.Motion.actionBar, value: model.selection.isActive)
            .animation(Theme.Motion.scrim, value: confirmsDelete)
            .sheet(item: $sheet) { item in
                switch item {
                case .category:
                    LedgerCategorySheet(count: model.selection.ids.count) { category in
                        model.editMany(Array(model.selection.ids)) { $0.category = category }
                        sheet = nil
                        end()
                    }
                    .onAllSelectionSheet()
                case .tag:
                    LedgerTagSheet(count: model.selection.ids.count, known: model.knownTags) { tags in
                        model.editMany(Array(model.selection.ids)) { override in
                            for tag in tags where !override.tags.contains(tag) { override.tags.append(tag) }
                        }
                        sheet = nil
                        end()
                    }
                    .onAllSelectionSheet()
                case let .settle(key):
                    SettlementSheet(model: model, eventKey: key)
                }
            }
            .fullScreenCover(isPresented: $isPickingEvent) {
                LedgerEventPicker(model: model, entries: pickEntries, onApplied: end)
            }
            .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button("확인", role: .cancel) {}
            }
    }

    private func end() { withAnimation(Theme.Motion.selectSlide) { model.selection.end() } }

    /// The picked ones as the ledger lists them (read when an action needs more than their ids).
    private func pickedEntries() async -> [LedgerListEntry] {
        (await model.ledgerSections() ?? []).flatMap(\.entries).filter { model.selection.contains($0.id) }
    }

    private func perform(_ action: LedgerSelectionBar.Action) {
        switch action {
        case .category: sheet = .category
        case .tag: sheet = .tag
        case .event: Task { pickEntries = await pickedEntries(); isPickingEvent = true }
        case .delete: confirmDelete()
        case .settle: Task { await settleSelected() }
        case .group: groupOrUngroup()
        }
    }

    /// 풀기 when the picks are exactly one bundle the user made; otherwise 묶기.
    private var picksAreOneBundle: Bool {
        let groups = Set(model.selection.ids.map { model.bundleGroup(of: $0) })
        guard groups.count == 1, let group = groups.first ?? nil else { return false }
        return model.transactionOverrides.byTransaction.filter { $0.value.group == group }.count == model.selection.ids.count
    }

    private func groupOrUngroup() {
        let ids = Array(model.selection.ids)
        if picksAreOneBundle {
            model.ungroupTransactions(ids)
        } else if ids.count < 2 {
            notice = "묶으려면 거래를 두 건 이상 골라 주세요."
            return
        } else {
            model.groupTransactions(ids)
        }
        end()
    }

    /// Only typed-in transactions can be deleted; what the bank or card reported stays.
    private func confirmDelete() {
        let ids = model.selection.ids
        let manual = ids.filter { $0.rawValue.hasPrefix(ManualTransaction.idPrefix) }
        if manual.isEmpty {
            notice = "카드·통장에서 온 거래는 지울 수 없어요."
        } else if manual.count < ids.count {
            notice = "카드·통장에서 온 거래는 지울 수 없어요. 직접 입력한 거래만 골라서 지워 주세요."
        } else {
            confirmsDelete = true
        }
    }

    private func deleteSelected() {
        model.removeManuals(model.selection.ids)
        end()
    }

    /// Settling is per event: it opens for the one event every picked transaction is in.
    private func settleSelected() async {
        let entries = await pickedEntries()
        let activities = Set(entries.flatMap { $0.portions.compactMap(\.activityID) })
        let everyOneLinked = entries.allSatisfy { entry in entry.portions.contains { $0.activityID != nil } }
        guard everyOneLinked, activities.count == 1, let activity = activities.first, let first = entries.first else {
            notice = "같은 일정에 들어 있는 거래만 정산할 수 있어요. 먼저 '일정'에서 한 일정으로 모아 주세요."
            return
        }
        let day = model.dayZone.localDate(of: first.transaction.occurredAtUnixMilliseconds)
        let timelines = await model.readDays((-3...3).map { day.adding(days: $0) }).compactMap(\.timeline)
        guard let block = timelines.flatMap(\.blocks).first(where: { $0.activity?.activityID == activity }) else {
            notice = "이 일정을 찾지 못했어요. 일정에서 정산해 주세요."
            return
        }
        sheet = .settle(block.eventKey)
    }
}

/// The design's selection box: an empty circle on every row while selecting, filled blue with a white check on a picked one.
struct SelectCheck: View {
    let picked: Bool

    var body: some View {
        Circle().strokeBorder(picked ? Theme.accentStrong : Theme.disabled, lineWidth: 1.5)
            .background(Circle().fill(picked ? Theme.accentStrong : .clear))
            .overlay { if picked { Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy)).foregroundStyle(.white) } }
            .frame(width: 22, height: 22)
    }
}

/// The check that opens in at the start of a row when selection mode begins: its width goes from 0 to 22 (plus the gap) and pushes the row along.
struct SelectCheckSlot: View {
    let selecting: Bool
    let picked: Bool
    var gap: CGFloat = 8

    var body: some View {
        // The box grows from a point as it opens and shrinks back as it closes (it is not cut off by a narrowing frame), while its width, and the gap,
        // make the row slide along with the same spring.
        SelectCheck(picked: picked)
            .scaleEffect(selecting ? 1 : 0.2, anchor: .leading)
            .opacity(selecting ? 1 : 0)
            .frame(width: selecting ? 22 : 0, height: 22, alignment: .leading)
            .padding(.trailing, selecting ? gap : 0)
            .animation(Theme.Motion.selectSlide, value: selecting)
            .animation(Theme.Motion.select, value: picked)
    }
}
