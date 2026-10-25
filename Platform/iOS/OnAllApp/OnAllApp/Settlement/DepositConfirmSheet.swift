import NEOBudgetCalendar
import NEOBudgetCore
import SwiftUI

/// The app setting for money that came in beyond what was owed: by default it is extra income; the user can have it taken off the expense it
/// paid back instead, so no income category appears (`docs/ledger-behavior.md`, 정산 이후 결정 4). Set in 설정.
enum SurplusSetting {
    static let key = "settlement.surplusTreatment"

    static func current(_ defaults: UserDefaults = .standard) -> SurplusTreatment {
        defaults.string(forKey: key).flatMap(SurplusTreatment.init(rawValue:)) ?? .income
    }
}

/// Picks which request a deposit pays and records it (`DepositConfirmation`). The sheet says up front what the amount will do: close the request,
/// leave a rest, or leave an excess, and asks the two things only the user can answer (forgive the rest? remember this name?).
struct DepositConfirmSheet: View {
    let model: AppModel
    let deposit: LedgerDeposit
    let life: LifeState
    let senderName: String
    var purchaseTitles: [LedgerEntryID: String] = [:]
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SurplusSetting.key) private var surplusRaw = SurplusTreatment.income.rawValue
    @State private var picked: ObligationID?
    @State private var pickedGathering: ActivityID?
    @State private var shortChoice = DepositConfirmation.ShortChoice.keepOpen
    @State private var rememberAlias = false
    @State private var isSaving = false
    @State private var failed = false

    private var review: DepositReview {
        let sender = deposit.title.flatMap { name in life.persons.values.first { !$0.isSelf && $0.matches(name: name) } }
        return life.depositReview(from: sender?.id, currency: deposit.amount.currency)
    }

    private var requests: [Obligation] {
        guard case let .askToConfirm(ids, _) = review else { return [] }
        return ids.compactMap { life.obligations[$0] }
    }

    private var gatherings: [Activity] {
        guard case let .askToConfirm(_, ids) = review else { return [] }
        return ids.compactMap { life.activities[$0] }
    }

    private var chosen: Obligation? { picked.flatMap { life.obligations[$0] } }
    private var fit: DepositConfirmation.Fit? { chosen.map { DepositConfirmation.fit(deposit, $0, in: life) } }
    private var money: (Int64) -> String { { Formatting.money($0, currency: deposit.amount.currency) } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    AmountHero(label: "\(senderName)님이 보낸 돈", amount: "+" + money(deposit.amount.minorUnits))
                }
                .onAllCardRow()
                Section {
                    ForEach(requests, id: \.id) { obligation in
                        pickRow(
                            name: life.persons[obligation.counterpartyID]?.displayName ?? "알 수 없음",
                            title: obligation.activityID.flatMap { life.activities[$0]?.displayTitle }
                                ?? obligation.originTransactionID.flatMap { purchaseTitles[$0] } ?? obligation.label ?? "정산",
                            trailing: DepositConfirmation.remaining(of: obligation, in: life).map { "남은 " + money($0) } ?? "금액 몰라요",
                            isPicked: picked == obligation.id
                        ) { picked = obligation.id; pickedGathering = nil }
                    }
                    ForEach(gatherings, id: \.id) { activity in
                        pickRow(name: senderName, title: activity.displayTitle, trailing: "요청 없음", isPicked: pickedGathering == activity.id) {
                            pickedGathering = activity.id; picked = nil
                        }
                    }
                } header: {
                    Text("어느 정산인가요?")
                } footer: {
                    if !gatherings.isEmpty { Text("요청이 없는 모임을 고르면 이 금액만큼 받을 돈으로 만들고 바로 받은 것으로 기록해요.") }
                }
                .onAllCardRow()
                if let fit { fitSection(fit) }
                if let chosen, let person = life.persons[chosen.counterpartyID], DepositConfirmation.isNewAlias(deposit, for: person) {
                    Section {
                        Toggle(isOn: $rememberAlias) {
                            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                                Text("‘\(deposit.title ?? "")’을(를) \(person.displayName)님 이름으로 기억할까요?").font(Theme.Typo.rowTitle)
                                Text("다음부터 이 이름으로 온 돈은 같은 친구로 봐요.").font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary)
                            }
                        }
                    }
                    .onAllCardRow()
                }
            }
            .onAllGroupedScreen()
            .navigationTitle("이 돈이 정산이 맞나요?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } } }
            .primaryActionBar(isShown: true, isEnabled: (picked != nil || pickedGathering != nil) && !isSaving) {
                Task { await save() }
            } label: {
                Text(picked == nil && pickedGathering == nil ? "정산을 골라 주세요" : "정산으로 기록하기")
            }
            .alert("저장하지 못했어요", isPresented: $failed) { Button("확인", role: .cancel) {} } message: { Text("다시 시도해 주세요.") }
        }
    }

    @ViewBuilder
    private func fitSection(_ fit: DepositConfirmation.Fit) -> some View {
        switch fit {
        case .exact:
            Section { Label("받을 돈과 같아요. 정산이 끝나요.", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.accent).font(Theme.Typo.label) }
                .onAllCardRow()
        case .unknownAmount:
            Section { Text("받을 금액을 몰랐던 정산이에요. 이 금액이 받을 돈으로 정해져요.").font(Theme.Typo.label).foregroundStyle(Theme.textSecondary) }
                .onAllCardRow()
        case let .short(left):
            Section {
                choiceRow("남은 \(money(left)) 더 받기", detail: "정산을 열어 두고 나머지를 기다려요.", isOn: shortChoice == .keepOpen) { shortChoice = .keepOpen }
                choiceRow("여기서 정산 닫기", detail: "나머지 \(money(left))은 안 받아요. 내 몫에 남아요.", isOn: shortChoice == .close) { shortChoice = .close }
            } header: {
                Text("\(money(left)) 덜 왔어요")
            }
            .onAllCardRow()
        case let .over(extra):
            Section {
                Label(surplusRaw == SurplusTreatment.reduceSpending.rawValue
                      ? "\(money(extra)) 더 왔어요. 설정에 따라 별도 수입 없이 이 지출에서 그만큼 차감해요."
                      : "\(money(extra)) 더 왔어요. 지출을 줄이지 않고 따로 수입으로 기록해요.",
                      systemImage: "info.circle").font(Theme.Typo.label).foregroundStyle(Theme.textSecondary)
            } footer: {
                Text("설정에서 바꿀 수 있어요.")
            }
            .onAllCardRow()
        }
    }

    private func pickRow(name: String, title: String, trailing: String, isPicked: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.m) {
                PersonAvatar(name: name, size: 36, isSelected: isPicked)
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text(title).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text(name).font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: Theme.Space.s)
                Text(trailing).font(Theme.Typo.caption).foregroundStyle(Theme.textSecondary)
            }
        }
        .accessibilityAddTraits(isPicked ? .isSelected : [])
    }

    private func choiceRow(_ title: String, detail: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text(title).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary)
                    Text(detail).font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                if isOn { Image(systemName: "checkmark").foregroundStyle(Theme.accent).fontWeight(.semibold) }
            }
        }
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let provenance = ActivityEditing.provenance(now: model.nowMilliseconds)
        let done: Bool
        if let chosen {
            done = await model.record(deposit, to: chosen, life: life, shortChoice: shortChoice, rememberAlias: rememberAlias)
        } else if let pickedGathering {
            done = await model.record(deposit, forGathering: pickedGathering, senderName: senderName, life: life, provenance: provenance)
        } else { return }
        if done { dismiss() } else { failed = true }
    }
}
