import NEOBudgetCalendar
import NEOBudgetCore
import SwiftUI

/// An event's settlement (`docs/ledger-behavior.md`, 정산 화면): who was there and how many, what each named person owes of what the user paid for
/// it, and the request that records it. Each change of people or headcount is one command, so the sheet always shows what is stored; the shares are
/// only a preview (`EventSettlementPlan`) until "정산 요청 만들기" saves them as obligations, which is also when a deposit can settle them.
struct SettlementSheet: View {
    let model: AppModel
    let eventKey: CalendarEventKey
    @Environment(\.dismiss) private var dismiss
    @State private var life: LifeState?
    @State private var newPerson = ""
    /// Hand-set shares, by person, as typed (whole won).
    @State private var fixedText: [PersonID: String] = [:]
    @State private var failure: String?
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Group {
                if let block {
                    form(block)
                } else {
                    ContentUnavailableView("일정을 찾을 수 없습니다", systemImage: "calendar.badge.exclamationmark")
                }
            }
            .navigationTitle((block?.title).map { $0 + " 정산" } ?? "정산")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } } }
        }
        .task(id: model.dataGeneration) { life = await model.lifeState() }
    }

    // MARK: What is stored

    private var block: EventBlock? {
        let days = model.strip.compactMap(\.timeline) + model.visibleTimelines
        for day in days { if let found = day.blocks.first(where: { $0.eventKey == eventKey }) { return found } }
        return nil
    }

    private var activity: Activity? { life?.activity(forEvent: eventKey) }
    private var me: Person? { life?.persons.values.first(where: \.isSelf) }

    private var others: [(id: PersonID, name: String)] {
        guard let life, let activity else { return [] }
        return activity.participants.map(\.personID)
            .compactMap { id -> (id: PersonID, name: String)? in life.persons[id].flatMap { $0.isSelf ? nil : (id: id, name: $0.displayName) } }
            .sorted { $0.name < $1.name }
    }

    /// What the user paid for the event: linked spending less linked refunds, in won. `nil` while some of it is not known exactly.
    private func total(_ block: EventBlock) -> (minorUnits: Int64, currency: String)? {
        guard let spend = block.allocatedSpend.first, spend.isFullyKnown else { return nil }
        let refunds = block.allocatedRefunds.first { $0.currency == spend.currency }
        guard refunds?.isFullyKnown ?? true else { return nil }
        return (spend.knownMinorUnits - (refunds?.knownMinorUnits ?? 0), spend.currency)
    }

    private var obligations: [Obligation] {
        guard let life, let activity else { return [] }
        return life.obligations(forActivity: activity.id).filter { $0.status != .cancelled }
    }

    private var existingComponent: ExpenseComponentID? {
        guard let life, let activity else { return nil }
        return life.components.values.first { $0.activityID == activity.id && $0.label == "정산" }?.id
    }

    private var fixed: [PersonID: Int64] { fixedText.compactMapValues { Int64($0.filter(\.isNumber)) } }

    // MARK: The form

    private func form(_ block: EventBlock) -> some View {
        let paid = total(block)
        let plan = paid.flatMap { try? EventSettlementPlan.make(
            totalMinorUnits: $0.minorUnits, currency: $0.currency, me: me?.id ?? PersonID(rawValue: "~me"), others: others,
            headcount: activity?.headcount?.value, fixed: fixed
        ) }
        return Form {
            Section {
                LabeledContent("결제한 금액") {
                    Text(paid.map { Formatting.money($0.minorUnits, currency: $0.currency) } ?? "확정되지 않음").monospacedDigit()
                }
            } footer: {
                if paid == nil { Text("일정에 연결된 거래의 금액이 모두 확정되어야 나눌 수 있습니다.") }
            }
            if let failure { Section { Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote) } }
            Section("인원") {
                Stepper(value: Binding(
                    get: { max(activity?.headcount?.value ?? 0, others.count + 1) },
                    set: { run(.setHeadcount(SetHeadcountInput(target: .event(eventKey), headcount: $0, provenance: ActivityEditing.provenance(now: model.nowMilliseconds)))) }
                ), in: (others.count + 1)...50) {
                    LabeledContent("나 포함", value: "\(max(activity?.headcount?.value ?? 0, others.count + 1))명")
                }
                .disabled(!obligations.isEmpty)
            }
            Section {
                ForEach(model.catalog.people.filter { !$0.isSelf }) { person in
                    let on = others.contains { $0.id == person.id }
                    Button {
                        run(ActivityEditing.setParticipant(person.id, on: !on, event: eventKey, now: model.nowMilliseconds))
                    } label: {
                        HStack {
                            Text(person.name).foregroundStyle(.primary)
                            Spacer()
                            if on { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                        }
                    }
                    .disabled(!obligations.isEmpty)
                }
                HStack {
                    TextField("새 사람", text: $newPerson).submitLabel(.done)
                    Button("추가") { addPerson() }.disabled(ActivityEditing.cleanName(newPerson) == nil || !obligations.isEmpty)
                }
            } header: {
                Text("함께한 사람")
            }
            if obligations.isEmpty {
                if let plan { shareSection(plan) }
            } else {
                requestedSection()
            }
        }
    }

    private func shareSection(_ plan: EventSettlementPlan) -> some View {
        Section {
            ForEach(plan.others) { share in
                HStack {
                    Text(share.name)
                    Spacer()
                    TextField(Formatting.money(share.minorUnits, currency: plan.currency), text: Binding(
                        get: { fixedText[share.personID] ?? "" },
                        set: { fixedText[share.personID] = $0.isEmpty ? nil : $0 }
                    ))
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(maxWidth: 140)
                }
            }
            if plan.unnamedCount > 0 {
                LabeledContent("이름 없는 \(plan.unnamedCount)명", value: "각 " + Formatting.money(plan.unnamedShareMinorUnits, currency: plan.currency))
            }
            LabeledContent("내 몫", value: Formatting.money(plan.myShareMinorUnits, currency: plan.currency))
            Button {
                Task { await request(plan) }
            } label: {
                Label("정산 요청 만들기", systemImage: "person.2.badge.gearshape")
            }
            .disabled(plan.others.isEmpty || isSaving)
        } header: {
            Text("나눠 낼 금액")
        } footer: {
            Text(plan.unnamedCount > 0
                 ? "금액을 비워 두면 똑같이 나눕니다. 이름 없는 사람의 몫은 이름을 넣기 전까지 받을 돈으로 잡히지 않습니다."
                 : "금액을 비워 두면 똑같이 나눕니다.")
        }
    }

    private func requestedSection() -> some View {
        Section {
            ForEach(obligations, id: \.id) { obligation in
                let name = life?.persons[obligation.counterpartyID]?.displayName ?? "알 수 없음"
                let applied = life?.appliedMinorUnits(for: obligation.id) ?? 0
                LabeledContent {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Formatting.knowledge(obligation.amount.knowledge, currency: obligation.currency)).monospacedDigit()
                        Text(statusText(obligation.status, applied: applied, currency: obligation.currency)).font(.caption).foregroundStyle(.secondary)
                    }
                } label: {
                    Text(obligation.direction == .receivable ? name + "에게 받을 돈" : name + "에게 줄 돈")
                }
            }
            if obligations.allSatisfy({ (life?.appliedMinorUnits(for: $0.id) ?? 0) == 0 }) {
                Button("다시 나누기", role: .destructive) { Task { await cancelRequests() } }
            }
        } header: {
            Text("정산 요청")
        }
    }

    private func statusText(_ status: ObligationStatus, applied: Int64, currency: String) -> String {
        switch status {
        case .open: return "아직 안 받음"
        case .partiallySettled: return Formatting.money(applied, currency: currency) + " 받음"
        case .settled: return "정산 완료"
        case .cancelled: return "취소됨"
        }
    }

    // MARK: Commands

    private func addPerson() {
        guard let name = ActivityEditing.cleanName(newPerson) else { return }
        newPerson = ""
        Task {
            let person = Person(id: PersonID(rawValue: ActivityEditing.newID(prefix: "person")), displayName: name)
            _ = await model.perform(.upsertPerson(person))
            run(ActivityEditing.setParticipant(person.id, on: true, event: eventKey, now: model.nowMilliseconds))
        }
    }

    /// Saves the plan as the event's settlement component and asks each named person for their share.
    private func request(_ plan: EventSettlementPlan) async {
        isSaving = true
        defer { isSaving = false }
        let provenance = ActivityEditing.provenance(now: model.nowMilliseconds)
        var meID = me?.id
        if meID == nil {
            let created = Person(id: PersonID(rawValue: ActivityEditing.newID(prefix: "person")), displayName: "나", isSelf: true)
            guard case .applied? = await model.perform(.upsertPerson(created)) else { return fail() }
            meID = created.id
        }
        guard let meID else { return fail() }
        // The plan was made before the user was a person; the shares do not depend on who the user is.
        let input = plan.component(for: eventKey, me: meID, existing: existingComponent, provenance: provenance)
        guard case let .applied(applied)? = await model.perform(.upsertExpenseComponent(input)), let componentID = applied.componentID ?? existingComponent else { return fail() }
        guard case .applied? = await model.perform(.generateObligations(GenerateObligationsInput(componentID: componentID, provenance: provenance))) else { return fail() }
        fixedText = [:]
        failure = nil
    }

    private func cancelRequests() async {
        let provenance = ActivityEditing.provenance(now: model.nowMilliseconds)
        for obligation in obligations {
            if case let .rejected(reason)? = await model.perform(.cancelObligation(CancelObligationInput(obligationID: obligation.id, by: provenance))) {
                failure = "취소하지 못했습니다. (\(reason))"
                return
            }
        }
    }

    private func fail() { failure = "정산 요청을 저장하지 못했습니다." }

    private func run(_ command: CalendarCommand) {
        Task {
            let outcome = await model.perform(command)
            if case let .rejected(reason)? = outcome { failure = "저장하지 못했습니다. (\(reason))" } else { failure = nil }
        }
    }
}
