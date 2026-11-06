import NEOBudgetCalendar
import NEOBudgetCore
import SwiftUI

/// The calendar's list style (design ledger-v20 ①②): the selected day's title, then its events and transactions in the order they happen. An event is
/// a box tinted with its colour that holds the transactions that went to it (a name and a time only, once it has begun; a larger title when it is
/// still to come); a transaction no event holds is a plain row. It reads the same `DayTimeline` as the rail.
struct DayListView: View {
    let day: LocalDate
    let timeline: DayTimeline?
    let model: AppModel
    let onSelect: (TimelineSelection) -> Void
    let onOpenTransaction: (LedgerEntryID) -> Void
    var onOpenIncome: (LedgerEntryID) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let incomes = model.incomeByDay[day] ?? []
            let plan = timeline.map { Plan($0, nowMilliseconds: model.nowMilliseconds, incomes: incomes, groupOf: { model.bundleGroup(of: $0) }, noChargeTaps: model.noChargeTaps) }
            HStack(alignment: .firstTextBaseline) {
                Text("\(day.day)일 \(Formatting.weekdayShort(day))요일").font(Theme.Typo.section).foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
                if let plan, plan.eventCount > 0, plan.rowCount == 0 || plan.futureOnly {
                    Text("일정 \(plan.eventCount)건").font(.onAll(size: 15, weight: .medium)).foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 28).padding(.top, 8).padding(.bottom, 8)
            if let plan {
                ForEach(plan.items) { item in
                    switch item.kind {
                    case let .row(row): pickable(row, inEvent: false)
                    case let .bundle(bundle): bundleView(bundle)
                    case .nowLine: NowLine(minute: Int((model.nowMilliseconds - (timeline?.dayStartUnixMilliseconds ?? 0)) / 60_000))
                    case let .event(block, rows, isFuture):
                        EventBox(block: block, rows: rows, isFuture: isFuture, isLive: isGoingOn(block, timeline), onSelect: { onSelect(.event(block)) }, rowView: { AnyView(pickable($0, inEvent: true)) })
                    }
                }
                if plan.items.isEmpty {
                    Text("일정과 거래가 없어요").font(Theme.Typo.label).foregroundStyle(Theme.textTertiary).padding(.horizontal, 28).padding(.vertical, Theme.Space.s)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 48)
            }
        }
        .padding(.bottom, Theme.Space.xl)
    }

    /// The event is going on now (the design's 진행 중): today, begun and not over.
    private func isGoingOn(_ block: EventBlock, _ timeline: DayTimeline?) -> Bool {
        guard let timeline, day == model.today else { return false }
        let now = Int((model.nowMilliseconds - timeline.dayStartUnixMilliseconds) / 60_000)
        return block.displayStartMinute <= now && now < block.displayEndMinute
    }

    /// A transaction row: a tap opens it (or, in selection mode, picks it); a long press starts selection with it.
    private func pickable(_ row: Plan.Row, inEvent: Bool) -> some View {
        TransactionRow(row: row, inEvent: inEvent, selected: model.selection.contains(row.id), selecting: model.selection.isActive && !row.isIncome)
            .listTap {
                if row.isIncome { return onOpenIncome(row.id) }
                guard !HapticHold.justHeld(row.id.rawValue) else { return }
                if model.selection.isActive { withAnimation(Theme.Motion.selectSlide) { model.selection.toggle(row.id) } } else { onOpenTransaction(row.id) }
            }
            .hapticLongPress(id: row.id.rawValue, enabled: !model.selection.isActive && !row.isIncome) {
                withAnimation(Theme.Motion.selectSlide) { model.selection.begin(with: row.id) }
            }
    }

    /// A bundle: one row (its tile with the count, its name, the sum); a tap opens it to list its transactions, or in selection mode picks all of them.
    private func bundleView(_ bundle: Plan.Bundle) -> some View {
        let open = model.openBundles.contains(bundle.key)
        let ids = bundle.rows.map(\.id)
        let picked = model.selection.containsAll(ids)
        return VStack(alignment: .leading, spacing: 0) {
            BundleListRow(bundle: bundle, open: open, selecting: model.selection.isActive, picked: picked)
                .listTap {
                    guard !HapticHold.justHeld(bundle.key) else { return }
                    if model.selection.isActive { withAnimation(Theme.Motion.selectSlide) { model.selection.toggleAll(ids) } } else {
                        withAnimation(.snappy(duration: 0.28)) { if open { model.openBundles.remove(bundle.key) } else { model.openBundles.insert(bundle.key) } }
                    }
                }
                .hapticLongPress(id: bundle.key, enabled: !model.selection.isActive) {
                    withAnimation(Theme.Motion.selectSlide) { model.selection.begin(withAll: ids) }
                }
            if open {
                ForEach(bundle.rows) { row in pickable(row, inEvent: false).padding(.leading, 40) }
            }
        }
    }

    /// What the list draws for one day, in time order.
    struct Plan {
        struct Row: Identifiable {
            let id: LedgerEntryID
            let minute: Int
            var title: String
            let category: CanonicalCategoryID?
            let amountText: String
            let isIncoming: Bool
            /// A deposit: its own tile, opens nothing.
            var isIncome = false
            var amountMinor: Int64 = 0
        }

        /// Transactions shown as one row (the design's 묶음): the name, how many, and what they came to; opened, the transactions are listed under it.
        struct Bundle: Identifiable {
            let key: String
            let title: String
            let rows: [Row]
            var id: String { key }
            var total: Int64 { rows.reduce(0) { $0 + $1.amountMinor } }
        }

        struct Item: Identifiable {
            enum Kind { case row(Row), event(EventBlock, [Row], isFuture: Bool), bundle(Bundle), nowLine }
            let id: String
            let minute: Int
            let kind: Kind
        }

        let items: [Item]
        let eventCount: Int
        let rowCount: Int
        /// Nothing of the day has happened yet.
        let futureOnly: Bool

        init(_ timeline: DayTimeline, nowMilliseconds: Int64, incomes: [IncomeItem] = [], groupOf: (LedgerEntryID) -> String? = { _ in nil }, noChargeTaps: [Int64] = []) {
            let raw = (nowMilliseconds - timeline.dayStartUnixMilliseconds) / 60_000
            let now = Int(max(-1, min(Int64(timeline.railEndMinute + 1), raw)))
            func row(_ id: LedgerEntryID, _ minute: Int, _ title: String?, _ category: CanonicalCategoryID?, _ money: Money, incoming: Bool) -> Row {
                Row(id: id, minute: minute, title: title ?? "거래", category: category, amountText: RailPlan.railAmount(Formatting.money(money.minorUnits, currency: money.currency), incoming: incoming), isIncoming: incoming, amountMinor: money.minorUnits)
            }
            let blocks = timeline.blocks.sorted { ($0.displayStartMinute, $0.id.rawValue) < ($1.displayStartMinute, $1.id.rawValue) }
            let marked = Set(timeline.markers.map(\.transactionID))
            var items: [Item] = timeline.markers.map { marker in
                let loose = row(marker.transactionID, marker.positionMinute, marker.title, marker.categoryID, marker.amount, incoming: marker.flow == .refund)
                return Item(id: "m/" + marker.transactionID.rawValue, minute: marker.positionMinute, kind: .row(loose))
            }
            for income in incomes {
                let minute = Int(max(0, min(Int64(timeline.railEndMinute - 1), (income.occurredAtUnixMilliseconds - timeline.dayStartUnixMilliseconds) / 60_000)))
                let deposit = Row(id: income.id, minute: minute, title: income.title ?? "입금", category: nil, amountText: "+" + Formatting.grouped(income.minorUnits), isIncoming: true, isIncome: true)
                items.append(Item(id: "i/" + income.id.rawValue, minute: minute, kind: .row(deposit)))
            }
            var rowCount = items.count
            // Loose transactions that belong together become one bundle row at the first of them.
            let looseRows: [Row] = items.compactMap { if case let .row(row) = $0.kind, !row.isIncome { return row } else { return nil } }
            let keys = TransactionBundling.keys(
                looseRows.map { TransactionBundling.Candidate(id: $0.id, minute: $0.minute, title: $0.title, category: $0.category, amountMinor: $0.amountMinor, eligible: !$0.isIncoming) },
                dayStart: timeline.dayStartUnixMilliseconds, groupOf: groupOf, noChargeTaps: noChargeTaps
            )
            var byKey: [String: [Row]] = [:]
            for (row, key) in zip(looseRows, keys) { if let key { byKey[key, default: []].append(row) } }
            var placed = Set<String>()
            items = items.compactMap { item in
                guard case let .row(row) = item.kind, let at = looseRows.firstIndex(where: { $0.id == row.id }), let key = keys[at], let members = byKey[key] else { return item }
                guard placed.insert(key).inserted else { return nil }
                var ordered = members.sorted { ($0.minute, $0.id.rawValue) < ($1.minute, $1.id.rawValue) }
                var title = ordered[0].title + " 외 \(ordered.count - 1)건"
                if key.hasPrefix("a:") {
                    // A trip: called by its vehicle, its first charge the 승차 and the rest 하차.
                    title = TransitMode.groupName(for: ordered.map(\.title))
                    for index in ordered.indices { ordered[index].title = index == 0 ? "승차" : "하차" }
                }
                return Item(id: "b/" + key, minute: ordered[0].minute, kind: .bundle(Bundle(key: key, title: title, rows: ordered)))
            }
            for block in blocks {
                // A transaction wholly inside an event has no marker of its own; it is drawn from the event's allocations.
                let inside: [Row] = block.allocations.filter { $0.occursOnSelectedDay && !marked.contains($0.transactionID) }.map { item in
                    let minute = Int(max(0, min(Int64(timeline.railEndMinute - 1), (item.occurredAtUnixMilliseconds - timeline.dayStartUnixMilliseconds) / 60_000)))
                    return row(item.transactionID, minute, item.title, item.categoryID, item.transactionAmount, incoming: item.flow == .refund)
                }.sorted { ($0.minute, $0.id.rawValue) < ($1.minute, $1.id.rawValue) }
                rowCount += inside.count
                items.append(Item(id: "e/" + block.id.rawValue, minute: block.displayStartMinute, kind: .event(block, inside, isFuture: block.displayStartMinute >= now)))
            }
            // Today, with no event going on: the time of day as a hairline among the rows (the design's `.nowl`).
            if raw >= 0, raw < Int64(timeline.railEndMinute), !blocks.contains(where: { $0.displayStartMinute <= now && now < $0.displayEndMinute }) {
                items.append(Item(id: "now", minute: now, kind: .nowLine))
            }
            self.items = items.sorted { ($0.minute, $0.id) < ($1.minute, $1.id) }
            self.eventCount = blocks.count
            self.rowCount = rowCount
            self.futureOnly = !blocks.isEmpty && rowCount == 0 && blocks.allSatisfy { $0.displayStartMinute >= now }
        }
    }
}

private func clockText(_ minute: Int) -> String { String(format: "%02d:%02d", minute % 1440 / 60, minute % 60) }

private extension View {
    /// A row that opens on a tap: a tap gesture, not a `Button`, so a swipe that starts on it never opens it.
    func listTap(_ action: @escaping () -> Void) -> some View {
        contentShape(Rectangle()).onTapGesture(perform: action).accessibilityAddTraits(.isButton)
    }
}

/// The time of day as a hairline with its time at the right (the design's `.nowl`), in the blue of the rail's now-line.
private struct NowLine: View {
    let minute: Int

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(Theme.accent.opacity(0.55)).frame(height: 1)
            Text(clockText(minute)).font(.onAll(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.accent).padding(.leading, 6)
        }
        .frame(height: 16).padding(.horizontal, 28).padding(.vertical, 2)
        .accessibilityElement(children: .ignore).accessibilityLabel("지금 \(clockText(minute))")
    }
}

/// An event as a box in its colour: a small name and time while it is going or done, a title and time when it is still to come; its transactions under it.
private struct EventBox: View {
    let block: EventBlock
    let rows: [DayListView.Plan.Row]
    let isFuture: Bool
    var isLive = false
    let onSelect: () -> Void
    let rowView: (DayListView.Plan.Row) -> AnyView

    var body: some View {
        let color = Color(hex: block.calendarColorHex) ?? Theme.accent
        let range = clockText(block.displayStartMinute) + " – " + clockText(block.displayEndMinute)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                if isFuture {
                    Text(block.title).font(Theme.Typo.rowTitle.weight(.semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Spacer(minLength: Theme.Space.s)
                    Text(range).font(Theme.Typo.label).foregroundStyle(Theme.textSecondary)
                } else {
                    Text(block.title).font(.onAll(size: 13, weight: .medium)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    if isLive {
                        Text("진행 중").font(.onAll(size: 12, weight: .semibold)).foregroundStyle(Theme.accentStrong)
                            .padding(.horizontal, 8).padding(.vertical, 2).background(Theme.accentSoft, in: Capsule())
                    }
                    Spacer(minLength: Theme.Space.s)
                    Text(range).font(.onAll(size: 12)).foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, Theme.Space.l).padding(.top, isFuture ? 14 : 12).padding(.bottom, rows.isEmpty && !isFuture ? 12 : 2)
            .listTap(onSelect)
            ForEach(rows) { row in rowView(row) }
        }
        .padding(.bottom, rows.isEmpty ? (isFuture ? 12 : 0) : Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .padding(.horizontal, Theme.Space.m).padding(.top, Theme.Space.s)
    }
}

extension DayListView {
    /// One transaction: its category tile, name and time, the amount at the right (spent is blue, money in is red). Inside an event the tile is white.
    struct TransactionRow: View {
        let row: Plan.Row
        let inEvent: Bool
        var selected = false
        var selecting = false

        var body: some View {
            let tile = row.isIncome ? (icon: "down", tint: Theme.incomeSoft) : CategoryIcon.tile(for: row.category)
            HStack(spacing: 0) {
                SelectCheckSlot(selecting: selecting, picked: selected, gap: Theme.Space.m)
                LineIcon(name: tile.icon, size: 20).foregroundStyle(Theme.textSecondary)
                    .frame(width: 40, height: 40).background(inEvent ? Theme.surface : tile.tint, in: Circle())
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.title).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text(clockText(row.minute)).font(Theme.Typo.label).foregroundStyle(Theme.textTertiary)
                }
                .padding(.leading, Theme.Space.m)
                Spacer(minLength: Theme.Space.s)
                Text(row.amountText).font(row.isIncoming ? Font.onAll(size: 16, weight: .semibold).monospacedDigit() : Theme.Typo.amount)
                    .foregroundStyle(Theme.amountColor(isIncoming: row.isIncoming)).lineLimit(1).fixedSize()
            }
            .padding(.horizontal, inEvent ? Theme.Space.l : 28).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            // A picked row is tinted across its whole width (the design: `.row.picked`).
            .background(selected ? Theme.accentSoft : Color.clear)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(row.title), \(row.amountText), \(clockText(row.minute))")
        }
    }
}

/// A bundle's row in the list: the category tile with the count on it, the name with a chevron, what the legs were, and the sum.
private struct BundleListRow: View {
    let bundle: DayListView.Plan.Bundle
    let open: Bool
    let selecting: Bool
    let picked: Bool

    var body: some View {
        let tile = CategoryIcon.tile(for: bundle.rows[0].category)
        HStack(spacing: 0) {
            SelectCheckSlot(selecting: selecting, picked: picked, gap: Theme.Space.m)
            LineIcon(name: tile.icon, size: 20).foregroundStyle(Theme.textSecondary)
                .frame(width: 40, height: 40).background(tile.tint, in: Circle())
                .overlay(alignment: .bottomTrailing) {
                    Text("\(bundle.rows.count)").font(.onAll(size: 10, weight: .semibold)).foregroundStyle(.white)
                        .frame(minWidth: 16, minHeight: 16).padding(.horizontal, 3).background(Theme.actionBar, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.surface, lineWidth: 2)).offset(x: 4, y: 4)
                }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(bundle.title).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                Text(bundle.rows.map { "\($0.title) \(clockText($0.minute))" }.joined(separator: " · "))
                    .font(Theme.Typo.label).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            .padding(.leading, Theme.Space.m)
            Spacer(minLength: Theme.Space.s)
            Text(RailPlan.railAmount(Formatting.grouped(bundle.total), incoming: false)).font(Theme.Typo.amount)
                .foregroundStyle(Theme.amountColor(isIncoming: false)).lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 28).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(picked ? Theme.accentSoft : Color.clear)
    }
}
