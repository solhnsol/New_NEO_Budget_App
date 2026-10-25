import NEOBudgetCalendar
import NEOBudgetCore
import SwiftUI

/// Read-only details of one transaction from the ledger tab: the amount large at the top, then when and its category, then the activities it was
/// split into.
struct TransactionDetailView: View {
    let entry: LedgerListEntry
    let model: AppModel
    @State private var editing = false
    @State private var choosingEvent = false
    /// The entry as stored now: putting the transaction in an event or taking it out changes what this screen shows while it is open.
    @State private var fresh: LedgerListEntry?
    @State private var failure: String?
    private var current: LedgerListEntry { fresh ?? entry }
    private var zone: DisplayTimeZone { model.dayZone }
    private var zoneIdentifier: String { zone.identifier }

    var body: some View {
        let entry = current
        let transaction = entry.transaction
        let isRefund = transaction.flow == .refund
        List {
            Section {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(transaction.title ?? "거래").font(Theme.Typo.label).foregroundStyle(Theme.textSecondary)
                    Text((isRefund ? "+" : "") + Formatting.money(transaction.amount.minorUnits, currency: transaction.amount.currency))
                        .font(Theme.Typo.hero)
                        .foregroundStyle(Theme.amountColor(isIncoming: isRefund))
                    if isRefund { StatusBadge(text: "환불", tone: .accent).padding(.top, Theme.Space.xxs) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Theme.Space.s)
            }
            .onAllCardRow()
            Section {
                row("날짜", Formatting.dayTitle(zone.localDate(of: transaction.occurredAtUnixMilliseconds)))
                row("시각", Formatting.time(transaction.occurredAtUnixMilliseconds, zoneIdentifier: zoneIdentifier)
                    + (transaction.timePrecision == .approximate ? " (알림 기준)" : ""))
                if let category = entry.categoryID {
                    LabeledContent {
                        Label(CategoryIcon.name(for: category) ?? category.rawValue, systemImage: CategoryIcon.symbol(for: category) ?? "tag").foregroundStyle(Theme.textPrimary)
                    } label: {
                        Text("분류").foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .onAllCardRow()
            if let memo = entry.override?.memo, !memo.isEmpty || !(entry.override?.tags ?? []).isEmpty {
                Section {
                    if !memo.isEmpty { Text(memo).foregroundStyle(Theme.textPrimary) }
                    if let tags = entry.override?.tags, !tags.isEmpty {
                        Text(tags.map { "#" + $0 }.joined(separator: " ")).foregroundStyle(Theme.accent)
                    }
                } header: {
                    Text("메모·태그")
                }
                .onAllCardRow()
            } else if let tags = entry.override?.tags, !tags.isEmpty {
                Section {
                    Text(tags.map { "#" + $0 }.joined(separator: " ")).foregroundStyle(Theme.accent)
                } header: {
                    Text("태그")
                }
                .onAllCardRow()
            }
            if !entry.offsets.isEmpty, let net = entry.netMinorUnits {
                Section {
                    ForEach(entry.offsets) { offset in
                        LabeledContent {
                            Text("+" + Formatting.money(offset.minorUnits, currency: transaction.amount.currency))
                                .font(Theme.Typo.amount).foregroundStyle(Theme.amountColor(isIncoming: true))
                        } label: {
                            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                                Text(offsetTitle(offset)).foregroundStyle(Theme.textPrimary)
                                Text(Formatting.shortDate(offset.occurredAtUnixMilliseconds, zoneIdentifier: zoneIdentifier))
                                    .font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary)
                            }
                        }
                    }
                    LabeledContent {
                        Text(Formatting.money(net, currency: transaction.amount.currency)).font(Theme.Typo.amount).foregroundStyle(Theme.textPrimary)
                    } label: {
                        Text("실제 부담").foregroundStyle(Theme.textSecondary)
                    }
                } header: {
                    Text("돌려받은 돈")
                } footer: {
                    Text("보기에만 반영돼요. 계좌·카드 내역과 카드 사용액은 결제한 금액 그대로예요.")
                }
                .onAllCardRow()
            }
            Section {
                if entry.portions.isEmpty {
                    Text("아직 연결된 활동이 없어요").foregroundStyle(Theme.textTertiary)
                } else {
                    ForEach(entry.portions, id: \.id) { portion in
                        HStack {
                            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                                Text(portion.activityTitle ?? "활동 없음").font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary)
                                if portion.eventMissing {
                                    Text("캘린더에서 삭제된 일정이에요").font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary)
                                }
                            }
                            Spacer()
                            Text(Formatting.knowledge(portion.amount, currency: transaction.amount.currency))
                                .font(Theme.Typo.amount).foregroundStyle(Theme.textPrimary)
                        }
                    }
                }
                if transaction.flow == .spend {
                    let linked = entry.portions.contains { $0.activityID != nil }
                    Button(linked ? "다른 일정으로 옮기기" : "일정에 넣기") { choosingEvent = true }
                    if linked {
                        Button("일정에서 빼기", role: .destructive) {
                            Task {
                                let outcome = await model.perform(ActivityEditing.unlink(transaction.id, now: model.nowMilliseconds))
                                if case let .rejected(reason)? = outcome { failure = "빼지 못했어요. (\(reason))" } else { failure = nil }
                            }
                        }
                    }
                }
                if let failure { Label(failure, systemImage: "exclamationmark.circle.fill").foregroundStyle(Theme.danger).font(Theme.Typo.caption) }
            } header: {
                Text("활동")
            } footer: {
                if entry.portions.isEmpty { Text("활동 없는 지출도 괜찮아요. 일정에 넣고 싶으면 위 버튼을 눌러 주세요.") }
                else if entry.portions.contains(where: { $0.activityID != nil }) { Text("일정에서 뺀 거래는 시간이 겹쳐도 다시 들어가지 않아요.") }
            }
            .onAllCardRow()
        }
        .onAllGroupedScreen()
        .navigationTitle(transaction.title ?? "거래")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("수정") { editing = true } } }
        .sheet(isPresented: $editing) { TransactionEditSheet(entry: current, model: model) }
        .sheet(isPresented: $choosingEvent) {
            TransactionEventSheet(model: model, transaction: current.transaction, currentActivities: Set(current.portions.compactMap(\.activityID)))
        }
        .task(id: [model.dataGeneration, model.overrideRevision]) {
            fresh = await model.ledgerSections()?.lazy.flatMap(\.entries).first { $0.id == entry.id }
        }
    }

    private func offsetTitle(_ offset: LedgerListEntry.Offset) -> String {
        switch offset.kind {
        case .refund: "환불"
        case let .settlement(from): from + " 정산"
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent {
            Text(value).multilineTextAlignment(.trailing).foregroundStyle(Theme.textPrimary)
        } label: {
            Text(label).foregroundStyle(Theme.textSecondary)
        }
    }
}
