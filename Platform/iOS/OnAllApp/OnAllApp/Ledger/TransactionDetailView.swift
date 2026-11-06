import NEOBudgetCalendar
import NEOBudgetCore
import SwiftUI

/// The sheet one transaction opens (design-v2 FULL-2 / DETAIL-1 / DETAIL-2): its name on a category tile, the amount large, the event it is in (or the
/// nearby events it could go into, each one tap to link), then when it happened, its category, memo and tags. Editing opens `TransactionEditSheet`.
struct TransactionDetailView: View {
    let entry: LedgerListEntry
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var choosingEvent = false
    /// The entry as stored now: putting the transaction in an event or taking it out changes what this sheet shows while it is open.
    @State private var fresh: LedgerListEntry?
    /// The events a few days around the transaction, nearest first.
    @State private var nearby: [ActivityEditing.EventChoice] = []
    @State private var failure: String?
    /// The notification text, loaded only when the app could not read a name from it.
    @State private var originalText: String?
    private var current: LedgerListEntry { fresh ?? entry }
    private var zoneIdentifier: String { model.dayZone.identifier }

    var body: some View {
        let entry = current
        let transaction = entry.transaction
        let isRefund = transaction.flow == .refund
        let currency = transaction.amount.currency
        let linkedIDs = Set(entry.portions.compactMap(\.activityID))
        let linked = nearby.filter { $0.activityID.map(linkedIDs.contains) ?? false }
        SheetScaffold {
            HStack(spacing: Theme.Space.m) {
                CategoryTile(category: entry.categoryID)
                Text(transaction.title ?? "거래").font(Theme.Typo.sheetTitle).foregroundStyle(Theme.textPrimary).lineLimit(2)
                Spacer(minLength: 0)
            }
            Text((isRefund ? "+" : "−") + Formatting.money(transaction.amount.minorUnits, currency: currency))
                .font(Theme.Typo.hero).foregroundStyle(Theme.amountColor(isIncoming: isRefund))
                .padding(.top, Theme.Space.xl)
            if transaction.title == nil { unreadNotice(entry) }
            if let failure { Text(failure).font(Theme.Typo.label).foregroundStyle(Theme.danger).padding(.top, Theme.Space.s) }
            if !entry.offsets.isEmpty, let net = entry.netMinorUnits { offsets(entry, net: net, currency: currency) }
            if transaction.flow == .spend { eventSection(entry, linked: linked, linkedIDs: linkedIDs) }
            SheetSectionLabel("상세")
            SheetRow(label: "결제 시각", value: dayText(transaction.occurredAtUnixMilliseconds) + " " + Formatting.clock24(transaction.occurredAtUnixMilliseconds, zoneIdentifier: zoneIdentifier)
                + (transaction.timePrecision == .approximate ? " (알림 기준)" : ""))
            SheetRow(label: "분류", value: CategoryIcon.name(for: entry.categoryID), showsChevron: true) { editing = true }
            SheetRow(label: "메모", value: entry.override?.memo.flatMap { $0.isEmpty ? nil : $0 }) { editing = true }
            SheetRow(label: "태그", value: entry.tags.isEmpty ? nil : entry.tags.map { "#" + $0 }.joined(separator: " "), showsDivider: false) { editing = true }
        } button: {
            Button("확인") { dismiss() }.buttonStyle(.onAllPrimary)
        }
        .onAllSheet(detents: [.large])
        .sheet(isPresented: $editing) { TransactionEditSheet(entry: current, model: model) }
        .fullScreenCover(isPresented: $choosingEvent) { LedgerEventPicker(model: model, entries: [current], onApplied: {}) }
        .task(id: [model.dataGeneration, model.overrideRevision]) {
            fresh = await model.ledgerSections()?.lazy.flatMap(\.entries).first { $0.id == entry.id }
            let day = model.dayZone.localDate(of: entry.transaction.occurredAtUnixMilliseconds)
            let timelines = await model.readDays((-3...3).map { day.adding(days: $0) }).compactMap(\.timeline)
            nearby = ActivityEditing.eventChoices(near: entry.transaction.occurredAtUnixMilliseconds, in: timelines)
        }
    }

    /// The name could not be read from the notification: say so, show what the notification said, and ask for the name.
    private func unreadNotice(_ entry: LedgerListEntry) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("알림에서 이름을 읽지 못했어요").font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary)
            if let originalText {
                Text(originalText).font(Theme.Typo.label).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Button("이름 입력하기") { editing = true }.font(Theme.Typo.smallButton).foregroundStyle(Theme.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.l)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .padding(.top, Theme.Space.l)
        .task { originalText = await model.originalNotification(for: entry.id).map(NotificationText.joined) }
    }

    private func dayText(_ unixMilliseconds: Int64) -> String {
        let day = model.dayZone.localDate(of: unixMilliseconds)
        return "\(day.month)월 \(day.day)일"
    }

    // MARK: Event

    @ViewBuilder
    private func eventSection(_ entry: LedgerListEntry, linked: [ActivityEditing.EventChoice], linkedIDs: Set<ActivityID>) -> some View {
        if linkedIDs.isEmpty {
            SheetSectionLabel("일정에 연결")
            ForEach(nearby.prefix(2)) { choice in
                eventRow(choice) {
                    Button("연결") { link(choice) }.font(Theme.Typo.smallButton).foregroundStyle(Theme.accent)
                }
            }
            SheetRow(label: "다른 일정 고르기", placeholder: nil, showsChevron: true, showsDivider: false) { choosingEvent = true }
        } else {
            SheetSectionLabel("연결된 일정")
            ForEach(linked) { choice in
                eventRow(choice) {
                    HStack(spacing: Theme.Space.l) {
                        Button("변경") { choosingEvent = true }
                        Button("빼기") { unlink(entry) }
                    }
                    .font(Theme.Typo.label).foregroundStyle(Theme.textTertiary)
                }
            }
            if linked.isEmpty, let title = entry.portions.compactMap(\.activityTitle).first {
                SheetRow(label: title, placeholder: nil, showsDivider: false)
            }
        }
    }

    private func eventRow<Trailing: View>(_ choice: ActivityEditing.EventChoice, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: Theme.Space.m) {
            RoundedRectangle(cornerRadius: 2).fill(Color(hex: choice.colorHex) ?? Theme.CalendarTint.blue.color).frame(width: 4, height: 40)
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(choice.title).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(Formatting.range24(choice.startUnixMilliseconds, choice.endUnixMilliseconds, zoneIdentifier: zoneIdentifier))
                    .font(Theme.Typo.label).foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: Theme.Space.s)
            trailing()
        }
        .frame(minHeight: 64)
    }

    private func link(_ choice: ActivityEditing.EventChoice) {
        Task {
            let outcome = await model.perform(ActivityEditing.link(current.transaction.id, event: choice.key, now: model.nowMilliseconds))
            if case let .rejected(reason)? = outcome { failure = "넣지 못했어요. (\(reason))" } else { failure = nil }
        }
    }

    private func unlink(_ entry: LedgerListEntry) {
        Task {
            let outcome = await model.perform(ActivityEditing.unlink(entry.transaction.id, now: model.nowMilliseconds))
            if case let .rejected(reason)? = outcome { failure = "빼지 못했어요. (\(reason))" } else { failure = nil }
        }
    }

    // MARK: Money that came back

    @ViewBuilder
    private func offsets(_ entry: LedgerListEntry, net: Int64, currency: String) -> some View {
        SheetSectionLabel("돌려받은 돈")
        ForEach(entry.offsets) { offset in
            SheetRow(label: offsetTitle(offset) + " · " + Formatting.shortDate(offset.occurredAtUnixMilliseconds, zoneIdentifier: zoneIdentifier),
                     value: "+" + Formatting.grouped(offset.minorUnits), valueColor: Theme.income, valueWeight: .semibold)
        }
        SheetRow(label: "실제 부담", value: Formatting.spent(net), valueColor: Theme.accent, valueWeight: .semibold)
    }

    private func offsetTitle(_ offset: LedgerListEntry.Offset) -> String {
        switch offset.kind {
        case .refund: "환불"
        case let .settlement(from): from + " 정산"
        case let .pending(from): from + " 정산 대기 중"
        case let .surplus(from): from + " 더 보낸 돈"
        }
    }
}
