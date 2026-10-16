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

    /// The event and the day it is on (`AppModel.locate`).
    private var located: (block: EventBlock, timeline: DayTimeline)? { model.locate(eventKey) }
    private var block: EventBlock? { located?.block }

    var body: some View {
        NavigationStack {
            Group {
                if let located { form(located.block, located.timeline) } else { ContentUnavailableView("일정을 찾을 수 없어요", systemImage: "calendar.badge.exclamationmark") }
            }
            .navigationTitle(block?.title ?? "일정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } } }
        }
    }

    private func form(_ block: EventBlock, _ timeline: DayTimeline) -> some View {
        let activity = block.activity
        return Form {
            Section {
                LabeledContent("시간", value: Formatting.timeRange(block.startUnixMilliseconds, block.endUnixMilliseconds, zoneIdentifier: timeline.timeZoneIdentifier))
                if let calendar = block.calendarTitle { LabeledContent("캘린더", value: calendar) }
            }
            .onAllCardRow()
            if let failure { Section { Label(failure, systemImage: "exclamationmark.circle.fill").foregroundStyle(Theme.danger).font(Theme.Typo.caption) }.onAllCardRow() }
            Section("무엇을 했나요") {
                Picker("유형", selection: Binding(
                    get: { activity?.activityType?.rawValue ?? "" },
                    set: { value in run(ActivityEditing.setType(value.isEmpty ? nil : ActivityTypeID(rawValue: value), event: eventKey, now: model.nowMilliseconds)) }
                )) {
                    Text("없음").tag("")
                    ForEach(model.catalog.types) { type in Text(type.name).tag(type.id) }
                }
            }
            .onAllCardRow()
            Section("어디서") {
                Picker("장소", selection: Binding(
                    get: { activity?.areaID?.rawValue ?? "" },
                    set: { value in run(ActivityEditing.setArea(value.isEmpty ? nil : AreaID(rawValue: value), event: eventKey, now: model.nowMilliseconds)) }
                )) {
                    Text("없음").tag("")
                    ForEach(model.catalog.areas) { area in Text(area.name).tag(area.id) }
                }
                addRow("새 장소", text: $newArea) { name in
                    let area = Area(id: AreaID(rawValue: ActivityEditing.newID(prefix: "area")), displayName: name)
                    await model.perform(.upsertArea(area))
                    run(ActivityEditing.setArea(area.id, event: eventKey, now: model.nowMilliseconds))
                }
            }
            .onAllCardRow()
            Section("누구와") {
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
            }
            .onAllCardRow()
            transactionSections(block, timeline)
        }
        .onAllGroupedScreen()
    }

    @ViewBuilder
    private func transactionSections(_ block: EventBlock, _ timeline: DayTimeline) -> some View {
        Section {
            if block.allocations.isEmpty {
                Text("아직 연결된 거래가 없어요. 일정과 연결하지 않은 거래도 괜찮아요.").font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary)
            }
            ForEach(AllocationOrdering.byTime(block.allocations), id: \.allocationID) { item in
                HStack(spacing: Theme.Space.m) {
                    transactionLabel(item.title, at: item.occurredAtUnixMilliseconds, timeline)
                    Spacer()
                    Text(Formatting.knowledge(item.allocatedAmount, currency: item.transactionAmount.currency)).font(Theme.Typo.amount)
                    Button("해제") { run(ActivityEditing.unlink(item.transactionID, now: model.nowMilliseconds)) }
                        .buttonStyle(.onAllSecondary)
                }
            }
        } header: {
            Text("연결된 거래")
        } footer: {
            if let total = LinkedTotal.text(spend: block.allocatedSpend, refunds: block.allocatedRefunds) { Text("합계 \(total)") }
        }
        .onAllCardRow()
        let candidates = ActivityEditing.linkCandidates(for: block, in: timeline)
        if !candidates.isEmpty {
            Section("연결할 수 있는 거래") {
                ForEach(candidates, id: \.transactionID) { marker in
                    HStack(spacing: Theme.Space.m) {
                        transactionLabel(marker.title, at: marker.occurredAtUnixMilliseconds, timeline)
                        Spacer()
                        Text(Formatting.money(marker.amount.minorUnits, currency: marker.amount.currency)).font(Theme.Typo.amount)
                        Button("연결") { run(ActivityEditing.link(marker.transactionID, event: eventKey, now: model.nowMilliseconds)) }
                            .buttonStyle(SecondaryButtonStyle(tint: Theme.accent))
                    }
                }
            }
            .onAllCardRow()
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
