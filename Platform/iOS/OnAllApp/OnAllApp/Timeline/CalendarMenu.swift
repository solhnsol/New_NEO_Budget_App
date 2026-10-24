import NEOBudgetCore
import SwiftUI

/// How the calendar shows a day: the time grid, or the list of cards (events with the transactions that went to them).
enum CalendarStyle: String, CaseIterable {
    case grid, list

    static let storageKey = "calendarStyle"
    var title: String { self == .grid ? "시간표" : "리스트" }
    var symbol: String { self == .grid ? "calendar.day.timeline.left" : "list.bullet" }
}

/// Where the ledger's own screens are opened from now that the ledger is not a tab.
enum LedgerDestination: String, Identifiable {
    case list, accounts
    var id: String { rawValue }
}

/// A transaction picked in the calendar, to open its details.
struct TransactionRef: Identifiable { let id: LedgerEntryID }

/// The calendar's one menu: how the day is shown, adding a transaction, and the ledger's list and account statements.
struct CalendarMenu: View {
    @Binding var style: CalendarStyle
    let onAdd: () -> Void
    let onOpen: (LedgerDestination) -> Void

    var body: some View {
        Menu {
            Picker("보기", selection: $style) {
                ForEach(CalendarStyle.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            Divider()
            Button { onAdd() } label: { Label("내역 추가", systemImage: "plus") }
            Button { onOpen(.list) } label: { Label("가계부 목록", systemImage: "list.bullet.rectangle") }
            Button { onOpen(.accounts) } label: { Label("계좌·카드", systemImage: "creditcard") }
        } label: {
            Image(systemName: "ellipsis.circle").font(.title3).frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .accessibilityLabel("메뉴")
    }
}
