import NEOBudgetCore
import SwiftUI

/// How the calendar shows a day: the time grid, or one day at a time as a page (events with the transactions that went to them), turned sideways.
enum CalendarStyle: String, CaseIterable {
    case grid, pager

    static let storageKey = "calendarStyle"
    var title: String { self == .grid ? "시간표" : "하루씩" }
    var symbol: String { self == .grid ? "calendar.day.timeline.left" : "rectangle.portrait.on.rectangle.portrait" }
    /// The style the one-tap button switches to.
    var next: CalendarStyle { self == .grid ? .pager : .grid }
}

/// Where the ledger's own screens are opened from (analysis and settings are tabs now).
enum LedgerDestination: String, Identifiable {
    case list, accounts
    var id: String { rawValue }
}

/// A transaction picked in the calendar, to open its details.
struct TransactionRef: Identifiable { let id: LedgerEntryID }

/// The header's right side (design): the list / calendar switch (the list opens the ledger; a long press on the calendar half turns the day view between
/// styles), search, and add.
struct CalendarMenu: View {
    @Binding var showsList: Bool
    let onAdd: () -> Void
    var onAddEvent: () -> Void = {}

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                segment("list", on: showsList) { showsList = true }
                segment("cal", on: !showsList) { showsList = false }
            }
            .padding(2).background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.segment, style: .continuous))
            .padding(.trailing, 6)
            icon("srch") {}
            Menu {
                Button { onAddEvent() } label: { Text("일정 추가") }
                Button { onAdd() } label: { Text("내역 추가") }
            } label: {
                LineIcon(name: "plus").foregroundStyle(Theme.textPrimary).frame(width: Theme.hitTarget, height: Theme.hitTarget).contentShape(Rectangle())
            }
        }
    }

    private func segment(_ name: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            LineIcon(name: name, size: 20)
                .foregroundStyle(on ? Theme.accentStrong : Theme.textTertiary)
                .frame(width: 36, height: Theme.segmentHeight)
                .background(on ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func icon(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { LineIcon(name: name).foregroundStyle(Theme.textPrimary).frame(width: Theme.hitTarget, height: Theme.hitTarget).contentShape(Rectangle()) }
            .buttonStyle(.plain)
    }
}
