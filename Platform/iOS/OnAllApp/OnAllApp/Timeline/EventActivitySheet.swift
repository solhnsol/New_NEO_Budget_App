import NEOBudgetCalendar
import NEOBudgetCore
import SwiftUI

/// The one place an event's meaning is edited: type, place, people and the transactions that belong to it. It is the event's
/// own sheet; there is no separate "activity" to create or attach first. Each choice is one command and the sheet shows what
/// is stored after it, so it never drifts from the timeline behind it.
struct EventActivitySheet: View {
    let model: AppModel
    let eventKey: CalendarEventKey
    @Environment(\.dismiss) private var dismiss
    @State private var newArea = ""
    @State private var failure: String?
    /// Transactions of the day before and after the event's day, so a payment just outside the day can still be linked.
    @State private var neighbours: [TransactionMarkerItem] = []
    @State private var picked: Set<LedgerEntryID> = []

    /// The event and the day it is on (`AppModel.locate`).
    private var located: (block: EventBlock, timeline: DayTimeline)? { model.locate(eventKey) }
    private var block: EventBlock? { located?.block }

    var body: some View {
        Group {
            if let located { form(located.block, located.timeline) } else { ContentUnavailableView("일정을 찾을 수 없어요", systemImage: "calendar.badge.exclamationmark") }
        }
        .onAllSheet(detents: [.large])
        .task(id: model.dataGeneration) {
            guard let day = located?.timeline.day else { return }
            let days = await model.readDays([day.adding(days: -1), day.adding(days: 1)])
            neighbours = days.compactMap(\.timeline).flatMap(\.markers)
        }
    }

    /// The design's detail sheet (FULL-3 / DETAIL-4): title block, gray-label rows, chips, linked spending, and one pinned 확인.
    private func form(_ block: EventBlock, _ timeline: DayTimeline) -> some View {
        let activity = block.activity
        let time = Formatting.range24(block.startUnixMilliseconds, block.endUnixMilliseconds, zoneIdentifier: timeline.timeZoneIdentifier)
        return SheetScaffold {
            SheetTitleBlock(title: block.title, lines: [time, block.calendarTitle ?? ""].filter { !$0.isEmpty }, barColor: Color(hex: block.calendarColorHex))
            if let failure { Text(failure).font(Theme.Typo.caption).foregroundStyle(Theme.danger).padding(.top, Theme.Space.s) }
            SheetSectionLabel("무엇을 했나요")
            chips(model.catalog.types.map { ($0.id, $0.name) }, selected: activity?.activityType?.rawValue) { value in
                run(ActivityEditing.setType(value.map { ActivityTypeID(rawValue: $0) }, event: eventKey, now: model.nowMilliseconds))
            }
            SheetSectionLabel("어디서")
            chips(model.catalog.areas.map { ($0.id, $0.name) }, selected: activity?.areaID?.rawValue) { value in
                run(ActivityEditing.setArea(value.map { AreaID(rawValue: $0) }, event: eventKey, now: model.nowMilliseconds))
            }
            addRow("새 장소", text: $newArea) { name in
                let area = Area(id: AreaID(rawValue: ActivityEditing.newID(prefix: "area")), displayName: name)
                await model.perform(.upsertArea(area))
                run(ActivityEditing.setArea(area.id, event: eventKey, now: model.nowMilliseconds))
            }
            SheetSectionLabel("누구와")
            let chosen = Set(activity?.participantIDs ?? [])
            PeoplePicker(
                people: model.catalog.people, chosen: chosen,
                toggle: { id in run(ActivityEditing.setParticipant(id, on: !chosen.contains(id), event: eventKey, now: model.nowMilliseconds)) },
                add: { name in
                    Task {
                        let person = Person(id: PersonID(rawValue: ActivityEditing.newID(prefix: "person")), displayName: name)
                        await model.perform(.upsertPerson(person))
                        run(ActivityEditing.setParticipant(person.id, on: true, event: eventKey, now: model.nowMilliseconds))
                    }
                }
            )
            transactionSections(block, timeline)
        } button: {
            Button("확인") { dismiss() }.buttonStyle(.onAllPrimary)
        }
    }

    /// One row of chips: 없음 first, then each choice; the chosen one is lit.
    private func chips(_ items: [(id: String, name: String)], selected: String?, set: @escaping (String?) -> Void) -> some View {
        QuickFlow(spacing: 6) {
            chip("없음", on: selected == nil) { set(nil) }
            ForEach(items, id: \.id) { item in chip(item.name, on: selected == item.id) { set(item.id) } }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chip(_ text: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.onAll(size: 13, weight: on ? .medium : .regular)).foregroundStyle(on ? Theme.accentStrong : Theme.textSecondary)
                .padding(.horizontal, Theme.Space.m).frame(height: Theme.chipHeight)
                .background(on ? Theme.accentSoft : Theme.fill, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func transactionSections(_ block: EventBlock, _ timeline: DayTimeline) -> some View {
        SheetSectionLabel("이 일정의 지출")
        ForEach(AllocationOrdering.byTime(block.allocations), id: \.allocationID) { item in
            HStack(spacing: Theme.Space.m) {
                CategoryTile(category: item.categoryID)
                transactionLabel(item.title, at: item.occurredAtUnixMilliseconds, timeline)
                Spacer()
                Text(Formatting.knowledge(item.allocatedAmount, currency: item.transactionAmount.currency)).font(Theme.Typo.amount)
                Button("해제") { run(ActivityEditing.unlink(item.transactionID, now: model.nowMilliseconds)) }.buttonStyle(.onAllSecondary)
            }
            .frame(minHeight: 64)
        }
        if let total = LinkedTotal.text(spend: block.allocatedSpend, refunds: block.allocatedRefunds) { SheetRow(label: "내 지출 합계", value: total, valueColor: Theme.accent, valueWeight: .semibold) }
        let candidates = ActivityEditing.linkCandidates(for: block, among: timeline.markers + neighbours)
        if !candidates.isEmpty {
            SheetSectionLabel("연결할 수 있는 거래")
            ForEach(candidates, id: \.transactionID) { marker in
                let isPicked = picked.contains(marker.transactionID)
                Button {
                    if isPicked { picked.remove(marker.transactionID) } else { picked.insert(marker.transactionID) }
                } label: {
                    HStack(spacing: Theme.Space.m) {
                        Image(systemName: isPicked ? "checkmark.circle.fill" : "circle").foregroundStyle(isPicked ? Theme.accent : Theme.disabled)
                        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                            Text(marker.title ?? "거래").font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary)
                            Text(Formatting.shortDate(marker.occurredAtUnixMilliseconds, zoneIdentifier: timeline.timeZoneIdentifier) + " "
                                 + Formatting.time(marker.occurredAtUnixMilliseconds, zoneIdentifier: timeline.timeZoneIdentifier))
                                .font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary)
                        }
                        Spacer()
                        Text(Formatting.money(marker.amount.minorUnits, currency: marker.amount.currency)).font(Theme.Typo.amount).foregroundStyle(Theme.textPrimary)
                    }
                    .frame(minHeight: 64).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isPicked ? .isSelected : [])
            }
            if !picked.isEmpty {
                Button("\(picked.count)건 연결") {
                    let ids = candidates.map(\.transactionID).filter(picked.contains)
                    picked = []
                    // One after another: each edit reloads the days, and two at once would read each other's half-written state.
                    Task {
                        for id in ids {
                            let outcome = await model.perform(ActivityEditing.link(id, event: eventKey, now: model.nowMilliseconds))
                            if case let .rejected(reason)? = outcome { failure = "저장하지 못했어요. (\(reason))"; return }
                        }
                        failure = nil
                    }
                }
                .buttonStyle(.onAllSecondary).padding(.top, Theme.Space.s)
            }
        }
    }

    private func transactionLabel(_ title: String?, at time: Int64, _ timeline: DayTimeline) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            Text(title ?? "거래").font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary)
            Text(Formatting.time(time, zoneIdentifier: timeline.timeZoneIdentifier)).font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary)
        }
    }

    private func addRow(_ label: String, text: Binding<String>, add: @escaping (String) async -> Void) -> some View {
        // Return on the keyboard adds, the same as the button.
        let submit: () -> Void = {
            guard let name = ActivityEditing.cleanName(text.wrappedValue) else { return }
            text.wrappedValue = ""
            Task { await add(name) }
        }
        return HStack {
            TextField(label, text: text).submitLabel(.done).onSubmit(submit)
            Button("추가", action: submit)
                .buttonStyle(SecondaryButtonStyle(tint: Theme.accent))
                .disabled(ActivityEditing.cleanName(text.wrappedValue) == nil)
        }
    }

    private func run(_ command: CalendarCommand) {
        Task {
            let outcome = await model.perform(command)
            if case let .rejected(reason)? = outcome { failure = "저장하지 못했어요. (\(reason))" } else { failure = nil }
        }
    }
}

extension CalendarEventKey: @retroactive Identifiable {
    public var id: String { calendarID.rawValue + "/" + eventID.rawValue }
}
