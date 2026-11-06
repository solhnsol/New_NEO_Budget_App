import NEOBudgetCalendar
import NEOBudgetCore
import SwiftUI

/// The round tile of a category: the design's line icon on a pale tint. The categories the shared tile table has no icon for get their own here.
enum LedgerTile {
    static func of(_ category: CanonicalCategoryID?) -> (icon: String, tint: Color) {
        switch CategoryIcon.symbol(for: category) {
        case "cross.case": ("heart", Theme.CalendarTint.pink.soft)
        case "ticket": ("ticket", Theme.CalendarTint.purple.soft)
        case "house": ("house", Theme.CalendarTint.green.soft)
        case "airplane": ("plane", Theme.CalendarTint.teal.soft)
        case "gift": ("gift", Theme.CalendarTint.orange.soft)
        case "antenna.radiowaves.left.and.right": ("wifi", Theme.CalendarTint.blue.soft)
        default: CategoryIcon.tile(for: category)
        }
    }

    /// "14:20": 24-hour with two digits, as the design writes times on a row and an activity's box.
    static func clock(_ unixMilliseconds: Int64, zone: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone) ?? .current
        let parts = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: Double(unixMilliseconds) / 1_000))
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}

/// What a row needs to know about where it sits in its day card.
struct LedgerRowContext {
    /// Inside an activity's tinted box (the tile is white there).
    let inGroup: Bool
    let joinsAbove: Bool
    let joinsBelow: Bool
}

/// A day's entries cut into runs: transactions of one activity sit together in that activity's tinted box, the rest are plain rows on the card.
struct LedgerDayBlock: Identifiable {
    struct Group {
        let id: String
        let title: String
        let time: EventTimeRange?
        let tint: Theme.CalendarTint
    }

    let group: Group?
    let entries: [LedgerListEntry]
    var id: String { (group?.id ?? "plain") + "/" + (entries.first?.id.rawValue ?? "") }

    static func blocks(_ entries: [LedgerListEntry]) -> [LedgerDayBlock] {
        var result: [LedgerDayBlock] = []
        for entry in entries {
            let group = group(of: entry)
            if let last = result.last, last.group?.id == group?.id {
                result[result.count - 1] = LedgerDayBlock(group: group, entries: last.entries + [entry])
            } else {
                result.append(LedgerDayBlock(group: group, entries: [entry]))
            }
        }
        return result
    }

    /// The first activity the transaction went to; a split across several shows under the first.
    private static func group(of entry: LedgerListEntry) -> Group? {
        guard let portion = entry.portions.first(where: { $0.activityID != nil }), let id = portion.activityID, let title = portion.activityTitle else { return nil }
        // A stable pick (a hash seed would change every launch): the same activity always gets the same tint.
        let key = String(describing: id).unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        let tints: [Theme.CalendarTint] = [.blue, .orange, .green, .purple]
        return Group(id: String(describing: id), title: title, time: portion.activityTime, tint: tints[key % tints.count])
    }
}

/// One day as a white card: its date and net spending, then its rows; a group's rows sit in the activity's tinted box.
struct LedgerDayCard<Row: View>: View {
    let section: LedgerDaySection
    let title: String
    let isToday: Bool
    var netted: [String: Int64] = [:]
    let zoneIdentifier: String
    let selection: LedgerSelection
    @ViewBuilder let row: (LedgerListEntry, LedgerRowContext) -> Row

    var body: some View {
        VStack(spacing: 0) {
            header
            ForEach(LedgerDayBlock.blocks(section.entries)) { block in
                if let group = block.group {
                    VStack(spacing: 0) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(group.title).font(Theme.Typo.label).foregroundStyle(Theme.textSecondary).lineLimit(1)
                            Spacer(minLength: Theme.Space.s)
                            if let time = group.time { Text(Self.timeText(time, zone: zoneIdentifier)).font(Theme.Typo.label).foregroundStyle(Theme.textTertiary) }
                            // What the event cost the user (after settlements), so an event can be read as one amount.
                            Text(LedgerList.totals(block.entries).map { LedgerRow.amountText(abs($0.minorUnits), currency: $0.currency, isIncoming: $0.minorUnits < 0) }.joined(separator: " · "))
                                .font(Theme.Typo.label).monospacedDigit().foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.horizontal, Theme.Space.l).padding(.top, Theme.Space.m).padding(.bottom, Theme.Space.xxs)
                        rows(block, inGroup: true)
                    }
                    .padding(.bottom, Theme.Space.xs)
                    .background(group.tint.soft, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .padding(.horizontal, Theme.Space.m).padding(.top, 6)
                } else {
                    rows(block, inGroup: false)
                }
            }
        }
        .padding(.bottom, Theme.Space.s)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private func rows(_ block: LedgerDayBlock, inGroup: Bool) -> some View {
        ForEach(Array(block.entries.enumerated()), id: \.element.id) { index, entry in
            let joins = selection.joins(in: block.entries, at: index)
            row(entry, LedgerRowContext(inGroup: inGroup, joinsAbove: joins.above, joinsBelow: joins.below))
        }
    }

    private var header: some View {
        let totals = NettedSpendingTotals.adding(netted, to: section.totals)
        // A day whose refunds outweigh its spending got money back: "+3,000", not "−3,000".
        let isMoneyBack = !totals.isEmpty && totals.allSatisfy { $0.minorUnits < 0 }
        return HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(title).font(Theme.Typo.section).foregroundStyle(Theme.textPrimary)
            if isToday { StatusBadge(text: "오늘", tone: .accent) }
            Spacer(minLength: Theme.Space.s)
            Text(totals.map { LedgerRow.amountText($0.minorUnits < 0 ? -$0.minorUnits : $0.minorUnits, currency: $0.currency, isIncoming: $0.minorUnits < 0) }.joined(separator: " · "))
                .font(Theme.Typo.label).monospacedDigit().foregroundStyle(isMoneyBack ? Theme.accent : Theme.textTertiary)
        }
        .padding(.horizontal, 28).padding(.top, 14).padding(.bottom, Theme.Space.xs)
    }

    private static func timeText(_ time: EventTimeRange, zone: String) -> String {
        switch time {
        case let .timed(range): LedgerTile.clock(range.startUnixMilliseconds, zone: zone) + " – " + LedgerTile.clock(range.endUnixMilliseconds, zone: zone)
        case .allDay: "종일"
        }
    }
}

/// A row that dims to the gray fill while pressed (120 ms), for the row's tap and long press.
struct LedgerRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.fill : .clear)
            .animation(Theme.Motion.press, value: configuration.isPressed)
    }
}

/// One transaction line: its category on a round tile, what and when, the amount on the right (blue when spent, red when money came back). A
/// purchase that got money back shows what it cost after that, the charged amount struck through under it, and one small line per refund or settlement.
struct LedgerRow: View {
    let entry: LedgerListEntry
    let zoneIdentifier: String
    var context = LedgerRowContext(inGroup: false, joinsAbove: false, joinsBelow: false)
    var isSelected = false

    var body: some View {
        let transaction = entry.transaction
        let isRefund = transaction.flow == .refund
        let tile = LedgerTile.of(entry.categoryID)
        HStack(spacing: Theme.Space.m) {
            LineIcon(name: tile.icon, size: 20).foregroundStyle(Theme.textSecondary)
                .frame(width: 40, height: 40)
                .background(context.inGroup || isSelected ? Theme.surface : tile.tint, in: Circle())
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Theme.Space.xs) {
                    Text(transaction.title ?? "거래").font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    if entry.isWaitingForSettlement { StatusBadge(text: "정산 대기 중", tone: .caution) }
                }
                Text(subtitle).font(Theme.Typo.label).foregroundStyle(Theme.textTertiary).lineLimit(1)
                ForEach(entry.offsets) { offset in
                    Text(Self.offsetLine(offset, currency: transaction.amount.currency, zoneIdentifier: zoneIdentifier))
                        .font(Theme.Typo.label).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
            }
            Spacer(minLength: Theme.Space.s)
            VStack(alignment: .trailing, spacing: 0) {
                Text(Self.amountText(entry.netMinorUnits ?? transaction.amount.minorUnits, currency: transaction.amount.currency, isIncoming: isRefund))
                    .font(isRefund ? Font.onAll(size: 16, weight: .semibold).monospacedDigit() : Theme.Typo.amount)
                    .foregroundStyle(Theme.amountColor(isIncoming: isRefund))
                if entry.netMinorUnits != nil {
                    Text(Self.amountText(transaction.amount.minorUnits, currency: transaction.amount.currency, isIncoming: false))
                        .font(.onAll(size: 12)).monospacedDigit().strikethrough().foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .padding(.horizontal, context.inGroup ? Theme.Space.l : 28)
        .padding(.vertical, 10)
        .frame(minHeight: 60)
        .background(SelectableRowBackground(isSelected: isSelected, joinsAbove: context.joinsAbove, joinsBelow: context.joinsBelow, inset: context.inGroup ? 4 : Theme.Space.l))
        .contentShape(Rectangle())
    }

    /// "−5,800" for money spent, "+19,000" for money that came in; the design leaves the currency word off a row's amount.
    static func amountText(_ minorUnits: Int64, currency: String, isIncoming: Bool) -> String {
        let sign = isIncoming ? "+" : "−"
        if currency == "KRW" { return sign + Formatting.grouped(minorUnits) }
        return sign + Formatting.money(minorUnits, currency: currency)
    }

    /// "환불 19,000 · 10/9" or "민수 정산 30,000 · 10/9".
    static func offsetLine(_ offset: LedgerListEntry.Offset, currency: String, zoneIdentifier: String) -> String {
        let what: String
        switch offset.kind {
        case .refund: what = "환불"
        case let .settlement(from): what = from + " 정산"
        case let .pending(from): return from + " 정산 대기 중 " + Formatting.money(offset.minorUnits, currency: currency)
        case let .surplus(from): what = from + " 더 보낸 돈"
        }
        return what + " " + Formatting.money(offset.minorUnits, currency: currency) + " · " + Formatting.shortDate(offset.occurredAtUnixMilliseconds, zoneIdentifier: zoneIdentifier)
    }

    private var subtitle: String {
        var parts = [LedgerTile.clock(entry.transaction.occurredAtUnixMilliseconds, zone: zoneIdentifier)]
        if entry.transaction.flow == .refund { parts.append("환불") }
        if entry.transaction.id.rawValue.hasPrefix(ManualTransaction.idPrefix) { parts.append("직접 입력") }
        // Inside an activity's box the activity is the box's title.
        if !context.inGroup { parts.append(contentsOf: entry.activityTitles) }
        parts.append(contentsOf: entry.tags.map { "#" + $0 })
        return parts.joined(separator: " · ")
    }
}

/// A deposit nothing explains yet: who sent it and when, the amount in red with a plus.
struct DepositRow: View {
    let deposit: LedgerDeposit
    let zoneIdentifier: String

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            LineIcon(name: "bank", size: 20).foregroundStyle(Theme.textSecondary)
                .frame(width: 40, height: 40).background(Theme.incomeSoft, in: Circle())
            VStack(alignment: .leading, spacing: 0) {
                Text(deposit.title ?? "입금").font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(Formatting.shortDate(deposit.occurredAtUnixMilliseconds, zoneIdentifier: zoneIdentifier) + " "
                     + LedgerTile.clock(deposit.occurredAtUnixMilliseconds, zone: zoneIdentifier))
                    .font(Theme.Typo.label).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            Spacer(minLength: Theme.Space.s)
            Text(LedgerRow.amountText(deposit.amount.minorUnits, currency: deposit.amount.currency, isIncoming: true))
                .font(Font.onAll(size: 16, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.amountColor(isIncoming: true))
        }
        .padding(.horizontal, 28).padding(.vertical, 10).frame(minHeight: 60)
    }
}
