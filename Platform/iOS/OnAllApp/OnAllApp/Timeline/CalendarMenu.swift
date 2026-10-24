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

/// One tap switches how the day is shown (the button shows the style it switches to); the menu next to it adds a transaction and opens the
/// ledger's list and account statements.
struct CalendarMenu: View {
    @Binding var style: CalendarStyle
    let onAdd: () -> Void
    let onOpen: (LedgerDestination) -> Void

    private var other: CalendarStyle { style == .grid ? .list : .grid }

    var body: some View {
        HStack(spacing: 0) {
            Button { style = other } label: {
                Image(systemName: other.symbol).font(.body.weight(.semibold)).frame(width: 40, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel(other.title + " 보기로 바꾸기")
            menu
        }
    }

    private var menu: some View {
        Menu {
            Button { onAdd() } label: { Label("내역 추가", systemImage: "plus") }
            Button { onOpen(.list) } label: { Label("가계부 목록", systemImage: "list.bullet.rectangle") }
            Button { onOpen(.accounts) } label: { Label("계좌·카드", systemImage: "creditcard") }
        } label: {
            Image(systemName: "ellipsis.circle").font(.title3).frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .accessibilityLabel("메뉴")
    }
}
