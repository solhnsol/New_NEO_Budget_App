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
    @State private var newPerson = ""
    @State private var failure: String?

    private var block: EventBlock? { model.timeline?.blocks.first { $0.eventKey == eventKey } }

    var body: some View {
        NavigationStack {
            Group {
                if let block, let timeline = model.timeline { form(block, timeline) } else { ContentUnavailableView("일정을 찾을 수 없습니다", systemImage: "calendar.badge.exclamationmark") }
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
            if let failure { Section { Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote) } }
            Section("활동 유형") {
                Picker("유형", selection: Binding(
                    get: { activity?.activityType?.rawValue ?? "" },
                    set: { value in run(ActivityEditing.setType(value.isEmpty ? nil : ActivityTypeID(rawValue: value), event: eventKey, now: model.nowMilliseconds)) }
                )) {
                    Text("없음").tag("")
                    ForEach(model.catalog.types) { type in Text(type.name).tag(type.id) }
                }
            }
            Section("장소") {
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
            Section("참여자") {
                ForEach(model.catalog.people) { person in
                    let on = activity?.participantIDs.contains(person.id) ?? false
                    Button {
                        run(ActivityEditing.setParticipant(person.id, on: !on, event: eventKey, now: model.nowMilliseconds))
                    } label: {
                        HStack {
                            Text(person.isSelf ? "\(person.name) (나)" : person.name).foregroundStyle(.primary)
                            Spacer()
                            if on { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                        }
                    }
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
                addRow("새 사람", text: $newPerson) { name in
                    let person = Person(id: PersonID(rawValue: ActivityEditing.newID(prefix: "person")), displayName: name)
                    await model.perform(.upsertPerson(person))
                    run(ActivityEditing.setParticipant(person.id, on: true, event: eventKey, now: model.nowMilliseconds))
                }
            }
            transactionSections(block, timeline)
        }
    }

    @ViewBuilder
    private func transactionSections(_ block: EventBlock, _ timeline: DayTimeline) -> some View {
        Section {
            if block.allocations.isEmpty {
                Text("연결된 거래가 없습니다. 일정에 연결하지 않은 거래도 정상입니다.").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(AllocationOrdering.byTime(block.allocations), id: \.allocationID) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title ?? "거래")
                        Text(Formatting.time(item.occurredAtUnixMilliseconds, zoneIdentifier: timeline.timeZoneIdentifier))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Formatting.knowledge(item.allocatedAmount, currency: item.transactionAmount.currency)).monospacedDigit()
                    Button("해제") { run(ActivityEditing.unlink(item.transactionID, now: model.nowMilliseconds)) }
                        .buttonStyle(.borderless).font(.footnote)
                }
            }
        } header: {
            Text("연결된 거래")
        } footer: {
            if let total = LinkedTotal.text(spend: block.allocatedSpend, refunds: block.allocatedRefunds) { Text("합계 \(total)") }
        }
        let candidates = ActivityEditing.linkCandidates(for: block, in: timeline)
        if !candidates.isEmpty {
            Section("연결할 수 있는 거래") {
                ForEach(candidates, id: \.transactionID) { marker in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(marker.title ?? "거래")
                            Text(Formatting.time(marker.occurredAtUnixMilliseconds, zoneIdentifier: timeline.timeZoneIdentifier))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Formatting.money(marker.amount.minorUnits, currency: marker.amount.currency)).monospacedDigit()
                        Button("연결") { run(ActivityEditing.link(marker.transactionID, event: eventKey, now: model.nowMilliseconds)) }
                            .buttonStyle(.borderless).font(.footnote)
                    }
                }
            }
        }
    }

    private func addRow(_ label: String, text: Binding<String>, add: @escaping (String) async -> Void) -> some View {
        HStack {
            TextField(label, text: text).submitLabel(.done)
            Button("추가") {
                guard let name = ActivityEditing.cleanName(text.wrappedValue) else { return }
                text.wrappedValue = ""
                Task { await add(name) }
            }
            .disabled(ActivityEditing.cleanName(text.wrappedValue) == nil)
        }
    }

    private func run(_ command: CalendarCommand) {
        Task {
            let outcome = await model.perform(command)
            if case let .rejected(reason)? = outcome { failure = "저장하지 못했습니다. (\(reason))" } else { failure = nil }
        }
    }
}

extension CalendarEventKey: @retroactive Identifiable {
    public var id: String { calendarID.rawValue + "/" + eventID.rawValue }
}
