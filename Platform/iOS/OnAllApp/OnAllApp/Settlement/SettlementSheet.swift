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
    @State private var isConfirmingRedo = false
    /// The share being typed; the number pad has no return key, so the keyboard bar's 완료 clears it.
    @FocusState private var typingShare: PersonID?

    var body: some View {
        Group {
            if let block {
                form(block)
            } else {
                Text("일정을 찾을 수 없어요").font(Theme.Typo.rowTitle).foregroundStyle(Theme.textTertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.surface)
        .onAllSheet(detents: [.large])
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("완료") { typingShare = nil }.fontWeight(.semibold)
            }
        }
        .task(id: model.dataGeneration) { life = await model.lifeState() }
    }

    // MARK: What is stored

    private var block: EventBlock? { model.locate(eventKey)?.block }

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

    private func makePlan(_ block: EventBlock, fixed: [PersonID: Int64]) -> EventSettlementPlan? {
        total(block).flatMap { try? EventSettlementPlan.make(
            totalMinorUnits: $0.minorUnits, currency: $0.currency, me: me?.id ?? PersonID(rawValue: "~me"), others: others,
            headcount: activity?.headcount?.value, fixed: fixed
        ) }
    }

    /// Why there is nothing to split yet, under the amount; `nil` when there is.
    private func paidNote(_ block: EventBlock, _ paid: (minorUnits: Int64, currency: String)?) -> String? {
        if block.allocatedSpend.isEmpty { return "이 일정에 연결된 거래가 없어요. 일정에 거래를 연결하면 나눌 수 있어요." }
        guard let paid else { return "일정에 연결된 거래 금액이 모두 확정되면 나눌 수 있어요." }
        return paid.minorUnits > 0 ? nil : "환불을 빼면 나눌 금액이 없어요."
    }

    /// At least the people chosen and the user.
    private var headcount: (value: Int, least: Int) {
        let least = others.count + 1
        return (max(activity?.headcount?.value ?? 0, least), least)
    }

    private func form(_ block: EventBlock) -> some View {
        let paid = total(block)
        // Hand-set amounts over the total keep the rows (and the field being typed in) on screen with equal shares, and say what is wrong.
        let planAsTyped = makePlan(block, fixed: fixed)
        let isOverTotal = planAsTyped == nil && !fixed.isEmpty && makePlan(block, fixed: [:]) != nil
        let plan = planAsTyped ?? (isOverTotal ? makePlan(block, fixed: [:]) : nil)
        let isLocked = !obligations.isEmpty
        let currency = paid?.currency ?? "KRW"
        let receivable = isLocked
            ? obligations.filter { $0.direction == .receivable }.reduce(Int64(0)) { $0 + $1.amount.knowledge.bounds.lower }
            : (plan?.others.reduce(Int64(0)) { $0 + $1.minorUnits } ?? 0)
        return SheetScaffold {
            if plan != nil || isLocked {
                Text("받을 돈 " + Formatting.money(receivable, currency: currency)).font(Theme.Typo.hero).foregroundStyle(Theme.textPrimary)
                Text(block.title + (paid.map { " · 총 " + Formatting.money($0.minorUnits, currency: $0.currency) + "을 \(plan?.headcount ?? headcount.value)명이 나눠요" } ?? ""))
                    .font(Theme.Typo.label).foregroundStyle(Theme.textTertiary).padding(.top, Theme.Space.xs)
            } else {
                Text(paid.map { Formatting.money($0.minorUnits, currency: $0.currency) } ?? (block.allocatedSpend.isEmpty ? "아직 없어요" : "아직 몰라요"))
                    .font(Theme.Typo.hero).foregroundStyle(Theme.textPrimary)
                Text(block.title).font(Theme.Typo.label).foregroundStyle(Theme.textTertiary).padding(.top, Theme.Space.xs)
                if let note = paidNote(block, paid) { Text(note).font(Theme.Typo.label).foregroundStyle(Theme.textTertiary).padding(.top, Theme.Space.s) }
            }
            if let failure { Text(failure).font(Theme.Typo.label).foregroundStyle(Theme.danger).padding(.top, Theme.Space.s) }
            Theme.divider.frame(height: 1).padding(.top, Theme.Space.xl)
            if isLocked {
                requestedRows()
            } else if let plan {
                shareRows(plan, isOverTotal: isOverTotal)
            }
            SheetSectionLabel("함께한 사람")
            PeoplePicker(
                people: model.catalog.people, chosen: Set(others.map(\.id)), isLocked: isLocked,
                toggle: { id in run(ActivityEditing.setParticipant(id, on: !others.contains { $0.id == id }, event: eventKey, now: model.nowMilliseconds)) },
                add: addPerson
            )
            HeadcountRow(value: headcount.value, least: headcount.least, isLocked: isLocked) {
                run(.setHeadcount(SetHeadcountInput(target: .event(eventKey), headcount: $0, provenance: ActivityEditing.provenance(now: model.nowMilliseconds))))
            }
            .padding(.top, Theme.Space.m)
        } button: {
            if isLocked {
                Button("확인") { dismiss() }.buttonStyle(.onAllPrimary)
            } else {
                Button { if let plan, !isOverTotal { Task { await request(plan) } } } label: {
                    Text(isOverTotal ? "나눠 낼 금액을 고쳐 주세요" : plan.map { $0.others.isEmpty ? "함께한 사람을 골라 주세요" : "\($0.others.count)명에게 정산 요청 만들기" } ?? "정산 요청 만들기")
                }
                .buttonStyle(.onAllPrimary)
                .disabled(plan == nil || (plan?.others.isEmpty ?? true) || isOverTotal || isSaving)
            }
        }
        .confirmationDialog("정산 요청을 지우고 다시 나눌까요?", isPresented: $isConfirmingRedo, titleVisibility: .visible) {
            Button("요청 지우고 다시 나누기", role: .destructive) { Task { await cancelRequests() } }
            Button("그대로 두기", role: .cancel) {}
        } message: {
            Text("사람마다 만든 정산 요청이 지워지고, 사람과 금액을 다시 고를 수 있어요.")
        }
    }

    /// A person's name in gray and what they owe at the right; the amount is a field, empty for an equal share.
    private func shareRows(_ plan: EventSettlementPlan, isOverTotal: Bool) -> some View {
        VStack(spacing: 0) {
            if isOverTotal {
                Text("직접 적은 금액이 결제한 " + Formatting.money(plan.totalMinorUnits, currency: plan.currency) + "보다 많아요")
                    .font(Theme.Typo.label).foregroundStyle(Theme.danger).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, Theme.Space.s)
            }
            ForEach(plan.others) { share in
                HStack(spacing: Theme.Space.s) {
                    Text(share.name).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textTertiary)
                    Spacer()
                    TextField(Formatting.grouped(share.minorUnits), text: Binding(
                        get: { fixedText[share.personID] ?? "" },
                        set: { fixedText[share.personID] = $0.isEmpty ? nil : $0 }
                    ))
                    .keyboardType(.numberPad)
                    .focused($typingShare, equals: share.personID)
                    .multilineTextAlignment(.trailing)
                    .font(Theme.Typo.amount)
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: 140)
                    Text("원").font(Theme.Typo.amount).foregroundStyle(Theme.textPrimary)
                }
                .frame(minHeight: Theme.rowHeight)
                .overlay(alignment: .bottom) { Theme.divider.frame(height: 1) }
            }
            if plan.unnamedCount > 0 {
                SheetRow(label: "이름 없는 \(plan.unnamedCount)명", value: "각 " + Formatting.money(plan.unnamedShareMinorUnits, currency: plan.currency), valueColor: Theme.textTertiary)
            }
            SheetRow(label: "내 몫", value: Formatting.money(plan.myShareMinorUnits, currency: plan.currency), valueColor: Theme.accent, valueWeight: .semibold, showsDivider: false)
        }
    }

    private func requestedRows() -> some View {
        VStack(spacing: 0) {
            ForEach(obligations, id: \.id) { obligation in
                let name = life?.persons[obligation.counterpartyID]?.displayName ?? "알 수 없음"
                let applied = life?.appliedMinorUnits(for: obligation.id) ?? 0
                HStack(spacing: Theme.Space.s) {
                    Text(name).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textTertiary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: Theme.Space.xxs) {
                        Text(Formatting.knowledge(obligation.amount.knowledge, currency: obligation.currency)).font(Theme.Typo.amount).foregroundStyle(Theme.textPrimary)
                        Text(statusText(obligation.status, applied: applied, currency: obligation.currency)).font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary)
                    }
                }
                .frame(minHeight: Theme.rowHeight)
                .overlay(alignment: .bottom) { Theme.divider.frame(height: 1) }
            }
            if obligations.allSatisfy({ (life?.appliedMinorUnits(for: $0.id) ?? 0) == 0 }) {
                SheetRow(label: "다시 나누기", placeholder: nil, showsChevron: true, showsDivider: false) { isConfirmingRedo = true }
            }
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
