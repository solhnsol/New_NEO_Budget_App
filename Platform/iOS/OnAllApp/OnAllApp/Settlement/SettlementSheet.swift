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
                    ContentUnavailableView("일정을 찾을 수 없어요", systemImage: "calendar.badge.exclamationmark")
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

    private func makePlan(_ block: EventBlock) -> EventSettlementPlan? {
        total(block).flatMap { try? EventSettlementPlan.make(
            totalMinorUnits: $0.minorUnits, currency: $0.currency, me: me?.id ?? PersonID(rawValue: "~me"), others: others,
            headcount: activity?.headcount?.value, fixed: fixed
        ) }
    }

    /// At least the people chosen and the user.
    private var headcount: (value: Int, least: Int) {
        let least = others.count + 1
        return (max(activity?.headcount?.value ?? 0, least), least)
    }

    private func form(_ block: EventBlock) -> some View {
        let paid = total(block)
        let plan = makePlan(block)
        let isLocked = !obligations.isEmpty
        return Form {
            Section {
                AmountHero(
                    label: "결제한 금액",
                    amount: paid.map { Formatting.money($0.minorUnits, currency: $0.currency) } ?? "아직 몰라요",
                    note: paid == nil ? "일정에 연결된 거래 금액이 모두 확정되면 나눌 수 있어요." : nil
                )
            }
            .onAllCardRow()
            if let failure { Section { Label(failure, systemImage: "exclamationmark.circle.fill").foregroundStyle(Theme.danger).font(Theme.Typo.caption) }.onAllCardRow() }
            Section {
                PeoplePicker(
                    people: model.catalog.people, chosen: Set(others.map(\.id)), isLocked: isLocked,
                    toggle: { id in run(ActivityEditing.setParticipant(id, on: !others.contains { $0.id == id }, event: eventKey, now: model.nowMilliseconds)) },
                    add: addPerson
                )
                HeadcountRow(value: headcount.value, least: headcount.least, isLocked: isLocked) {
                    run(.setHeadcount(SetHeadcountInput(target: .event(eventKey), headcount: $0, provenance: ActivityEditing.provenance(now: model.nowMilliseconds))))
                }
            } header: {
                Text("함께한 사람")
            } footer: {
                if isLocked { Text("정산 요청을 만든 뒤에는 사람과 인원을 바꿀 수 없어요. 바꾸려면 아래에서 다시 나누세요.") }
            }
            .onAllCardRow()
            if isLocked {
                requestedSection()
            } else if let plan {
                shareSection(plan)
            }
        }
        .onAllGroupedScreen()
        .primaryActionBar(isShown: !isLocked && plan != nil, isEnabled: !(plan?.others.isEmpty ?? true) && !isSaving) {
            if let plan { Task { await request(plan) } }
        } label: {
            Text(plan.map { $0.others.isEmpty ? "함께한 사람을 골라 주세요" : "\($0.others.count)명에게 정산 요청 만들기" } ?? "정산 요청 만들기")
        }
    }

    private func shareSection(_ plan: EventSettlementPlan) -> some View {
        Section {
            ForEach(plan.others) { share in
                HStack(spacing: Theme.Space.m) {
                    PersonAvatar(name: share.name, size: 32)
                    Text(share.name).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    TextField(Formatting.money(share.minorUnits, currency: plan.currency), text: Binding(
                        get: { fixedText[share.personID] ?? "" },
                        set: { fixedText[share.personID] = $0.isEmpty ? nil : $0 }
                    ))
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .font(Theme.Typo.amount)
                    .frame(maxWidth: 140)
                }
            }
            if plan.unnamedCount > 0 {
                HStack(spacing: Theme.Space.m) {
                    PersonAvatar(name: "?", size: 32)
                    Text("이름 없는 \(plan.unnamedCount)명").font(Theme.Typo.rowTitle).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text("각 " + Formatting.money(plan.unnamedShareMinorUnits, currency: plan.currency)).font(Theme.Typo.amount).foregroundStyle(Theme.textSecondary)
                }
            }
            HStack(spacing: Theme.Space.m) {
                PersonAvatar(name: "나", size: 32, isSelf: true)
                Text("내 몫").font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(Formatting.money(plan.myShareMinorUnits, currency: plan.currency)).font(Theme.Typo.amount).foregroundStyle(Theme.accent)
            }
        } header: {
            Text("나눠 낼 금액")
        } footer: {
            Text(plan.unnamedCount > 0
                 ? "금액을 비워 두면 똑같이 나눠요. 이름 없는 사람의 몫은 이름을 넣기 전까지 받을 돈으로 잡지 않아요."
                 : "금액을 비워 두면 똑같이 나눠요.")
        }
        .onAllCardRow()
    }

    private func requestedSection() -> some View {
        Section {
            ForEach(obligations, id: \.id) { obligation in
                let name = life?.persons[obligation.counterpartyID]?.displayName ?? "알 수 없음"
                let applied = life?.appliedMinorUnits(for: obligation.id) ?? 0
                HStack(spacing: Theme.Space.m) {
                    PersonAvatar(name: name, size: 32)
                    VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                        Text(name).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary)
                        Text(obligation.direction == .receivable ? "받을 돈" : "줄 돈").font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: Theme.Space.xs) {
                        Text(Formatting.knowledge(obligation.amount.knowledge, currency: obligation.currency)).font(Theme.Typo.amount).foregroundStyle(Theme.textPrimary)
                        StatusBadge(text: statusText(obligation.status, applied: applied, currency: obligation.currency), tone: tone(obligation.status))
                    }
                }
            }
            if obligations.allSatisfy({ (life?.appliedMinorUnits(for: $0.id) ?? 0) == 0 }) {
                Button("다시 나누기") { Task { await cancelRequests() } }
                    .buttonStyle(SecondaryButtonStyle(tint: Theme.danger))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        } header: {
            Text("정산 요청")
        }
        .onAllCardRow()
    }

    private func tone(_ status: ObligationStatus) -> StatusBadge.Tone {
        switch status {
        case .open, .partiallySettled: return .caution
        case .settled: return .accent
        case .cancelled: return .neutral
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

    private func addPerson(_ name: String) {
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
                failure = "취소하지 못했어요. (\(reason))"
                return
            }
        }
    }

    private func fail() { failure = "정산 요청을 저장하지 못했어요." }

    private func run(_ command: CalendarCommand) {
        Task {
            let outcome = await model.perform(command)
            if case let .rejected(reason)? = outcome { failure = "저장하지 못했어요. (\(reason))" } else { failure = nil }
        }
    }
}
