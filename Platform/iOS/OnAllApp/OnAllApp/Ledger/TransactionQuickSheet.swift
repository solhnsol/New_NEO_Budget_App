import NEOBudgetCalendar
import NEOBudgetCore
import SwiftUI

/// The small sheet a transaction opens from the calendar (the design's `openTx`): its name and amount on one line, then the category and the
/// linked event, each a row that opens its chips in place. The rest (payment method, time, delete) is under the fold; pulling the sheet up shows it.
struct TransactionQuickSheet: View {
    let entry: LedgerListEntry
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var fresh: LedgerListEntry?
    @State private var nearby: [ActivityEditing.EventChoice] = []
    @State private var opensCategory = false
    @State private var opensEvent = false
    @State private var choosingEvent = false
    @State private var detent = PresentationDetent.height(Self.quickHeight)

    static let quickHeight: CGFloat = 152
    private var current: LedgerListEntry { fresh ?? entry }
    private var zone: String { model.dayZone.identifier }

    var body: some View {
        let entry = current
        let transaction = entry.transaction
        let incoming = transaction.flow == .refund
        let linkedIDs = Set(entry.portions.compactMap(\.activityID))
        let linked = nearby.first { $0.activityID.map(linkedIDs.contains) ?? false }
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Theme.Space.s) {
                    Text(transaction.title ?? "거래").font(Theme.Typo.sheetTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Spacer(minLength: 0)
                    Text((incoming ? "+" : "−") + Formatting.grouped(transaction.amount.minorUnits) + "원")
                        .font(Theme.Typo.sheetTitle).foregroundStyle(Theme.amountColor(isIncoming: incoming))
                }
                .padding(.top, Theme.Space.xl)
                VStack(spacing: 0) {
                    row("분류", open: opensCategory, tappable: !incoming) {
                        HStack(spacing: 6) {
                            CategoryTile(category: entry.categoryID, size: 24)
                            Text(CategoryIcon.name(for: entry.categoryID) ?? "안 함")
                        }
                    } action: { withAnimation(Theme.Motion.sheet) { opensCategory.toggle() } }
                    if opensCategory && !incoming { categoryChips(entry) }
                    row("연결된 일정", open: opensEvent, tappable: true) {
                        HStack(spacing: 6) {
                            if let linked { Circle().fill(Color(hex: linked.colorHex) ?? Theme.accent).frame(width: 8, height: 8) }
                            Text(linked?.title ?? (entry.portions.compactMap(\.activityTitle).first ?? "없음"))
                        }
                    } action: { withAnimation(Theme.Motion.sheet) { opensEvent.toggle() } }
                    if opensEvent { eventChips(entry, linked: linked) }
                }
                .padding(.top, 6)
                VStack(spacing: 0) {
                    Color.clear.frame(height: Theme.Space.xl)
                    plainRow("시각", dayText(transaction.occurredAtUnixMilliseconds) + " " + Formatting.clock24(transaction.occurredAtUnixMilliseconds, zoneIdentifier: zone))
                    if transaction.id.rawValue.hasPrefix(ManualTransaction.idPrefix) {
                        Button { model.removeManual(entry.id); dismiss() } label: {
                            Text("삭제").font(.onAll(size: 16, weight: .semibold)).foregroundStyle(Theme.dangerStrong)
                                .frame(maxWidth: .infinity, minHeight: Theme.primaryButtonHeight)
                                .background(Theme.dangerSoft, in: RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
                        }
                        .padding(.top, Theme.Space.l)
                    }
                }
            }
            .padding(.horizontal, Theme.Space.xl).padding(.bottom, Theme.Space.l)
        }
        .scrollIndicators(.hidden)
        .background(Theme.surface)
        .tint(Theme.accent)
        .presentationDetents([.height(Self.quickHeight), .large], selection: $detent)
        .presentationCornerRadius(Theme.Radius.sheet)
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.surface)
        .sheet(isPresented: $choosingEvent) { TransactionEventSheet(model: model, transaction: current.transaction, currentActivities: linkedIDs) }
        .task(id: [model.dataGeneration, model.overrideRevision]) {
            fresh = await model.ledgerSections()?.lazy.flatMap(\.entries).first { $0.id == entry.id }
            let day = model.dayZone.localDate(of: entry.transaction.occurredAtUnixMilliseconds)
            let timelines = await model.readDays((-3...3).map { day.adding(days: $0) }).compactMap(\.timeline)
            nearby = ActivityEditing.eventChoices(near: entry.transaction.occurredAtUnixMilliseconds, in: timelines)
        }
    }

    private func dayText(_ unixMilliseconds: Int64) -> String {
        let day = model.dayZone.localDate(of: unixMilliseconds)
        return "\(day.month)월 \(day.day)일"
    }

    /// A row of the design's `kv`: a gray label, the value at the right, and a chevron that turns when the row is open; a hairline above it.
    private func row<V: View>(_ label: String, open: Bool, tappable: Bool, @ViewBuilder value: () -> V, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Text(label).foregroundStyle(Theme.textTertiary)
                Spacer(minLength: Theme.Space.s)
                value().foregroundStyle(Theme.textPrimary)
                if tappable {
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(open ? 180 : 0)).padding(.leading, Theme.Space.s)
                }
            }
            .font(.onAll(size: 15))
            .frame(minHeight: Theme.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!tappable)
        .overlay(alignment: .top) { Theme.divider.frame(height: 1) }
    }

    private func plainRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.textTertiary)
            Spacer()
            Text(value).foregroundStyle(Theme.textPrimary)
        }
        .font(.onAll(size: 15)).frame(minHeight: Theme.rowHeight)
        .overlay(alignment: .top) { Theme.divider.frame(height: 1) }
    }

    private func chip<L: View>(on: Bool, outlined: Bool = false, action: @escaping () -> Void, @ViewBuilder label: () -> L) -> some View {
        Button(action: action) {
            HStack(spacing: 6) { label() }
                .font(.onAll(size: 13, weight: on ? .medium : .regular))
                .foregroundStyle(on ? Theme.accentStrong : Theme.textSecondary)
                .padding(.horizontal, Theme.Space.m).frame(height: Theme.chipHeight)
                .background(on ? Theme.accentSoft : (outlined ? Color.clear : Theme.fill), in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: outlined && !on ? 1 : 0))
        }
        .buttonStyle(.plain)
    }

    private func categoryChips(_ entry: LedgerListEntry) -> some View {
        QuickFlow(spacing: 6) {
            ForEach(CategoryIcon.choices, id: \.id) { choice in
                let id = CanonicalCategoryID(rawValue: choice.id)
                chip(on: CategoryIcon.name(for: entry.categoryID) == choice.name) {
                    var override = entry.override ?? TransactionOverride()
                    override.category = id
                    model.edit(entry.id, to: override, originalTitle: entry.originalTitle)
                } label: {
                    CategoryTile(category: id, size: 20)
                    Text(choice.name)
                }
            }
        }
        .padding(.bottom, Theme.Space.m)
    }

    private func eventChips(_ entry: LedgerListEntry, linked: ActivityEditing.EventChoice?) -> some View {
        QuickFlow(spacing: 6) {
            chip(on: linked == nil) { Task { _ = await model.perform(ActivityEditing.unlink(entry.transaction.id, now: model.nowMilliseconds)) } } label: { Text("없음") }
            ForEach(nearby.prefix(2)) { choice in
                chip(on: choice == linked) {
                    Task { _ = await model.perform(ActivityEditing.link(entry.transaction.id, event: choice.key, now: model.nowMilliseconds)) }
                } label: {
                    Circle().fill(Color(hex: choice.colorHex) ?? Theme.accent).frame(width: 8, height: 8)
                    Text(choice.title)
                }
            }
            chip(on: false, outlined: true) { choosingEvent = true } label: { Text("선택") }
        }
        .padding(.bottom, Theme.Space.m)
    }
}

/// Chips that wrap onto the next line, left to right.
private struct QuickFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(width: bounds.width, subviews).frames
        for (subview, frame) in zip(subviews, frames) { subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: .unspecified) }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height); maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), frames)
    }
}
