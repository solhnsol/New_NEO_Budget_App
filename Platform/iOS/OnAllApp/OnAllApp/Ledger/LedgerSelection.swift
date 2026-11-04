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
    var radius: CGFloat = Theme.Radius.small + 4

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: 0.75, dy: 0.75)
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

/// A row in selection mode: light blue fill and a blue outline when picked (consecutive picks share one box).
struct SelectableRowBackground: View {
    let isSelected: Bool
    let joinsAbove: Bool
    let joinsBelow: Bool

    var body: some View {
        if isSelected {
            let shape = UnevenRoundedRectangle(
                topLeadingRadius: joinsAbove ? 0 : 16, bottomLeadingRadius: joinsBelow ? 0 : 16,
                bottomTrailingRadius: joinsBelow ? 0 : 16, topTrailingRadius: joinsAbove ? 0 : 16, style: .continuous
            )
            shape.fill(Theme.accentSoft)
                .overlay(SelectionBoxBorder(roundTop: !joinsAbove, roundBottom: !joinsBelow, radius: 16).stroke(Theme.accentLine, lineWidth: 1.5))
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

        var symbol: String {
            switch self {
            case .category: "square.grid.2x2"
            case .event: "calendar"
            case .tag: "tag"
            case .settle: "building.columns"
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
                        Image(systemName: action.symbol).font(.system(size: 20))
                        Text(action.label).font(Theme.Typo.caption)
                    }
                    .foregroundStyle(action == .delete ? Theme.actionBarDelete : Color.white)
                    .frame(maxWidth: .infinity, minHeight: Theme.hitTarget + 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .background(Theme.actionBar, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, Theme.cardMargin)
        .padding(.bottom, Theme.Space.s)
    }
}
