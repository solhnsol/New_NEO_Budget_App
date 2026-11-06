import NEOBudgetCalendar
import NEOBudgetCore
import SwiftUI

/// Which ledger rows are picked in selection mode. A long press starts it with that row; a tap adds or removes; taking away the last one ends it.
struct LedgerSelection: Equatable {
    private(set) var ids: Set<LedgerEntryID> = []
    private(set) var isActive = false

    mutating func begin(with id: LedgerEntryID) { ids = [id]; isActive = true }

    mutating func toggle(_ id: LedgerEntryID) {
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        if ids.isEmpty { isActive = false }
    }

    mutating func end() { ids = []; isActive = false }

    func contains(_ id: LedgerEntryID) -> Bool { ids.contains(id) }

    /// Whether the rows next to `index` are selected too: neighbours share one box instead of each drawing its own.
    func joins(in entries: [LedgerListEntry], at index: Int) -> (above: Bool, below: Bool) {
        (index > 0 && contains(entries[index - 1].id), index + 1 < entries.count && contains(entries[index + 1].id))
    }
}

/// The outline of a selected row; a side that joins a selected neighbour is left open.
struct SelectionBoxBorder: Shape {
    var roundTop: Bool
    var roundBottom: Bool
    var radius: CGFloat = 12

    func path(in rect: CGRect) -> Path {
        // The outline sits inside the box by half its width; on a joined side it runs to the edge so neighbours' lines meet.
        let r = CGRect(x: rect.minX + 0.75, y: rect.minY + (roundTop ? 0.75 : 0), width: rect.width - 1.5, height: rect.height - (roundTop ? 0.75 : 0) - (roundBottom ? 0.75 : 0))
        let top = roundTop ? radius : 0, bottom = roundBottom ? radius : 0
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY - bottom))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + top))
        if roundTop {
            p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX + top, y: r.minY), radius: top)
            p.addLine(to: CGPoint(x: r.maxX - top, y: r.minY))
            p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY + top), radius: top)
        } else {
            p.move(to: CGPoint(x: r.maxX, y: r.minY))
        }
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - bottom))
        if roundBottom {
            p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX - bottom, y: r.maxY), radius: bottom)
            p.addLine(to: CGPoint(x: r.minX + bottom, y: r.maxY))
            p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY - bottom), radius: bottom)
        }
        return p
    }
}

/// A picked row's box: light blue with a 1.5 blue outline, radius 12; consecutive picks share one box. `inset` is how far the box sits in from the row's sides.
struct SelectableRowBackground: View {
    let isSelected: Bool
    let joinsAbove: Bool
    let joinsBelow: Bool
    var inset: CGFloat = 16

    var body: some View {
        if isSelected {
            let shape = UnevenRoundedRectangle(
                topLeadingRadius: joinsAbove ? 0 : 12, bottomLeadingRadius: joinsBelow ? 0 : 12,
                bottomTrailingRadius: joinsBelow ? 0 : 12, topTrailingRadius: joinsAbove ? 0 : 12, style: .continuous
            )
            shape.fill(Theme.accentSoft)
                .overlay(SelectionBoxBorder(roundTop: !joinsAbove, roundBottom: !joinsBelow).stroke(Theme.accent, lineWidth: 1.5))
                .padding(.horizontal, inset)
        }
    }
}

/// The slate bar that rises at the bottom while rows are picked: 분류 · 일정 · 태그 · 정산 · 삭제.
struct LedgerSelectionBar: View {
    enum Action: CaseIterable {
        case category, event, tag, settle, delete

        var label: String {
            switch self {
            case .category: "분류"
            case .event: "일정"
            case .tag: "태그"
            case .settle: "정산"
            case .delete: "삭제"
            }
        }

        var icon: String {
            switch self {
            case .category: "cat"
            case .event: "cal"
            case .tag: "tag"
            case .settle: "bank"
            case .delete: "trash"
            }
        }
    }

    let perform: (Action) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Action.allCases, id: \.self) { action in
                Button { perform(action) } label: {
                    VStack(spacing: 4) {
                        LineIcon(name: action.icon, size: 22)
                        Text(action.label).font(Font.onAll(size: 11, weight: .medium))
                    }
                    .foregroundStyle(action == .delete ? Theme.actionBarDelete : Color.white)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4)
        .background(Theme.actionBar, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Theme.actionBar.opacity(0.25), radius: 9, y: 6)
        .padding(.horizontal, Theme.cardMargin)
        .padding(.bottom, 14)
    }
}

/// The delete confirmation of selection mode: a white card over a 42% scrim, 취소 on gray and 삭제 in warning red.
struct LedgerDeleteAlert: View {
    let count: Int
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        ZStack {
            Color(rgb: 0x191F28).opacity(0.42).ignoresSafeArea().onTapGesture(perform: cancel)
            VStack(spacing: 0) {
                Text("\(count)건을 삭제할까요?").font(Theme.Typo.section).foregroundStyle(Theme.textPrimary)
                Text("삭제하면 되돌릴 수 없어요").font(.onAll(size: 14)).foregroundStyle(Theme.textSecondary).padding(.top, 8)
                HStack(spacing: 8) {
                    button("취소", fill: Theme.fill, text: Theme.textSecondary, action: cancel)
                    button("삭제", fill: Theme.danger, text: .white, action: confirm)
                }
                .padding(.top, 20)
            }
            .multilineTextAlignment(.center)
            .padding(.top, 24).padding(.horizontal, 20).padding(.bottom, 16)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous))
            .padding(.horizontal, 40)
        }
        .accessibilityAddTraits(.isModal)
    }

    private func button(_ title: String, fill: Color, text: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Theme.Typo.smallButton).foregroundStyle(text)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(fill, in: RoundedRectangle(cornerRadius: Theme.Radius.smallButton, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
