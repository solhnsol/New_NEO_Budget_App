import NEOBudgetCalendar
import NEOBudgetCore
import SwiftUI

/// An event's settlement (`docs/ledger-behavior.md`, 정산 화면): who was there and how many, what each named person owes of what the user paid for
/// it, and the request that records it. Each change of people or headcount is one command, so the sheet always shows what is stored; the shares are
/// only a preview (`EventSettlementPlan`) until "정산 요청 만들기" saves them as obligations, which is also when a deposit can settle them.
struct SettlementSheet: View {
    let model: AppModel
    /// An event's activity, or a standalone one (transactions settled together without an event).
    let target: ActivityTarget
    @Environment(\.dismiss) private var dismiss
    @State private var life: LifeState?
    /// Hand-set shares, by person, as typed (whole won).
    @State private var fixedText: [PersonID: String] = [:]
    @State private var failure: String?
    @State private var isSaving = false
    @State private var isConfirmingRedo = false
    /// The share being typed; the number pad has no return key, so the keyboard bar's 완료 clears it.
    @FocusState private var typingShare: PersonID?

    init(model: AppModel, eventKey: CalendarEventKey) {
        self.model = model
        target = .event(eventKey)
    }

    init(model: AppModel, activityID: ActivityID) {
        self.model = model
        target = .activity(activityID)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let subject {
                    form(subject)
                } else {
                    ContentUnavailableView("정산할 거래를 찾을 수 없어요", systemImage: "calendar.badge.exclamationmark")
                }
            }
            .navigationTitle((subject?.title).map { $0 + " 정산" } ?? "정산")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("완료") { typingShare = nil }.fontWeight(.semibold)
                }
            }
        }
        .task(id: model.dataGeneration) { life = await model.lifeState() }
    }

    // MARK: What is stored

    /// What the sheet is about: the event or the standalone bundle, its name, and what the user paid for it.
    private struct Subject {
        let title: String
        let hasSpend: Bool
        let total: (minorUnits: Int64, currency: String)?
    }

    private var subject: Subject? {
        switch target {
        case let .event(key):
            guard let block = model.locate(key)?.block else { return nil }
            return Subject(title: block.title, hasSpend: !block.allocatedSpend.isEmpty, total: total(block))
        case let .activity(id):
            guard let life, let found = life.activities[id] else { return nil }
            return Subject(title: found.displayTitle, hasSpend: !life.allocations(forActivity: id).isEmpty, total: total(of: id, in: life))
        }
    }

    private var activity: Activity? {
        switch target {
        case let .event(key): return life?.activity(forEvent: key)
        case let .activity(id): return life?.activities[id]
        }
    }
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

    /// The same for a standalone activity, from its allocations: spending less refunds. `nil` while any portion is not exact.
    private func total(of id: ActivityID, in life: LifeState) -> (minorUnits: Int64, currency: String)? {
        var sum: Int64 = 0
        var currency: String?
        for allocation in life.allocations(forActivity: id) {
            guard case let .exact(value) = allocation.amount.knowledge, let set = life.allocationSet(for: allocation.transactionID) else { return nil }
            guard currency == nil || currency == set.transactionTotal.currency else { return nil }
            currency = set.transactionTotal.currency
            sum += set.flow == .refund ? -value : value
        }
        return currency.map { (sum, $0) }
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

    private func makePlan(_ subject: Subject, fixed: [PersonID: Int64]) -> EventSettlementPlan? {
        subject.total.flatMap { try? EventSettlementPlan.make(
            totalMinorUnits: $0.minorUnits, currency: $0.currency, me: me?.id ?? PersonID(rawValue: "~me"), others: others,
            headcount: activity?.headcount?.value, fixed: fixed
        ) }
    }

    /// Why there is nothing to split yet, under the amount; `nil` when there is.
    private func paidNote(_ subject: Subject, _ paid: (minorUnits: Int64, currency: String)?) -> String? {
        if !subject.hasSpend { return "연결된 거래가 없어요. 거래를 연결하면 나눌 수 있어요." }
        guard let paid else { return "연결된 거래 금액이 모두 확정되면 나눌 수 있어요." }
        return paid.minorUnits > 0 ? nil : "환불을 빼면 나눌 금액이 없어요."
    }

    /// At least the people chosen and the user.
    private var headcount: (value: Int, least: Int) {
        let least = others.count + 1
        return (max(activity?.headcount?.value ?? 0, least), least)
    }

    private func form(_ subject: Subject) -> some View {
        let paid = subject.total
        // Hand-set amounts over the total keep the rows (and the field being typed in) on screen with equal shares, and say what is wrong.
        let planAsTyped = makePlan(subject, fixed: fixed)
        let isOverTotal = planAsTyped == nil && !fixed.isEmpty && makePlan(subject, fixed: [:]) != nil
        let plan = planAsTyped ?? (isOverTotal ? makePlan(subject, fixed: [:]) : nil)
        let isLocked = !obligations.isEmpty
        return Form {
            Section {
                AmountHero(
                    label: "결제한 금액",
                    amount: paid.map { Formatting.money($0.minorUnits, currency: $0.currency) } ?? (!subject.hasSpend ? "아직 없어요" : "아직 몰라요"),
                    note: paidNote(subject, paid)
                )
            }
            .onAllCardRow()
            if let failure { Section { Label(failure, systemImage: "exclamationmark.circle.fill").foregroundStyle(Theme.danger).font(Theme.Typo.caption) }.onAllCardRow() }
            Section {
                PeoplePicker(
                    people: model.catalog.people, chosen: Set(others.map(\.id)), isLocked: isLocked,
                    toggle: { id in run(ActivityEditing.setParticipant(id, on: !others.contains { $0.id == id }, target: target, now: model.nowMilliseconds)) },
                    add: addPerson
                )
                HeadcountRow(value: headcount.value, least: headcount.least, isLocked: isLocked) {
                    run(.setHeadcount(SetHeadcountInput(target: target, headcount: $0, provenance: ActivityEditing.provenance(now: model.nowMilliseconds))))
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
                shareSection(plan, isOverTotal: isOverTotal)
            }
        }
        .onAllGroupedScreen()
        .scrollDismissesKeyboard(.interactively)
        .primaryActionBar(isShown: !isLocked && plan != nil, isEnabled: !(plan?.others.isEmpty ?? true) && !isOverTotal && !isSaving) {
            if let plan, !isOverTotal { Task { await request(plan) } }
        } label: {
            Text(isOverTotal ? "나눠 낼 금액을 고쳐 주세요" : plan.map { $0.others.isEmpty ? "함께한 사람을 골라 주세요" : "\($0.others.count)명에게 정산 요청 만들기" } ?? "정산 요청 만들기")
        }
        .confirmationDialog("정산 요청을 지우고 다시 나눌까요?", isPresented: $isConfirmingRedo, titleVisibility: .visible) {
            Button("요청 지우고 다시 나누기", role: .destructive) { Task { await cancelRequests() } }
            Button("그대로 두기", role: .cancel) {}
        } message: {
            Text("사람마다 만든 정산 요청이 지워지고, 사람과 금액을 다시 고를 수 있어요.")
        }
    }

    private func shareSection(_ plan: EventSettlementPlan, isOverTotal: Bool) -> some View {
        Section {
            if isOverTotal {
                Label("직접 적은 금액이 결제한 " + Formatting.money(plan.totalMinorUnits, currency: plan.currency) + "보다 많아요", systemImage: "exclamationmark.circle.fill")
                    .font(Theme.Typo.caption).foregroundStyle(Theme.danger)
            }
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
                    .focused($typingShare, equals: share.personID)
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
                Button("다시 나누기") { isConfirmingRedo = true }
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
            run(ActivityEditing.setParticipant(person.id, on: true, target: target, now: model.nowMilliseconds))
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
        let input = plan.component(for: target, me: meID, existing: existingComponent, provenance: provenance)
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
