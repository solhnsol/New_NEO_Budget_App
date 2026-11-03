import SwiftUI

/// A settings row: icon tile, title, a gray value on the right (the chevron comes from the NavigationLink).
struct MoreRowLabel: View {
    let symbol: String
    var tint: Color = Theme.textSecondary
    let title: String
    var value: String?

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            IconTile(systemName: symbol, tint: tint, size: 36)
            Text(title).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary)
            Spacer(minLength: Theme.Space.s)
            if let value { Text(value).font(Theme.Typo.label).foregroundStyle(Theme.textTertiary) }
        }
        .frame(minHeight: Theme.rowHeight - Theme.Space.l)
    }
}

/// The small gray section title above a card.
struct MoreSectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View { Text(text).font(Theme.Typo.label).foregroundStyle(Theme.textTertiary).textCase(nil) }
}

/// What the app can notify about. Each type has an on/off switch the main screen shows and its own detail screen.
enum NotificationKind: String, CaseIterable, Identifiable {
    case settlement, budget, eventSpending, categoryRequest, recurring

    var id: String { rawValue }

    var title: String {
        switch self {
        case .settlement: "정산 알림"
        case .budget: "예산 알림"
        case .eventSpending: "일정 지출 알림"
        case .categoryRequest: "분류 요청 알림"
        case .recurring: "반복 지출 알림"
        }
    }

    var symbol: String {
        switch self {
        case .settlement: "arrow.left.arrow.right"
        case .budget: "wonsign.circle"
        case .eventSpending: "calendar"
        case .categoryRequest: "tag"
        case .recurring: "repeat"
        }
    }

    var tint: Color {
        switch self {
        case .settlement: Theme.CalendarTint.pink.color
        case .budget: Theme.CalendarTint.green.color
        case .eventSpending: Theme.CalendarTint.blue.color
        case .categoryRequest: Theme.CalendarTint.purple.color
        case .recurring: Theme.CalendarTint.orange.color
        }
    }

    /// The mockup starts every type on except the category request.
    var defaultOn: Bool { self != .categoryRequest }

    var storageKey: String { "notify." + rawValue }

    static func isOn(_ kind: NotificationKind, _ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: kind.storageKey) as? Bool ?? kind.defaultOn
    }
}

/// Quiet hours: minutes after midnight, stored as two integers.
enum QuietHours {
    static let enabledKey = "notify.quiet.enabled"
    static let startKey = "notify.quiet.start"
    static let endKey = "notify.quiet.end"
    static let defaultStart = 23 * 60
    static let defaultEnd = 7 * 60

    /// `밤 11시 – 오전 7시`.
    static func summary(start: Int, end: Int) -> String { "\(label(start)) – \(label(end))" }

    static func label(_ minutes: Int) -> String {
        let hour = minutes / 60, minute = minutes % 60
        let period = hour < 6 ? "새벽" : hour < 12 ? "오전" : hour < 18 ? "오후" : "밤"
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        return "\(period) \(twelve)시" + (minute == 0 ? "" : " \(minute)분")
    }
}

/// One notification type's own screen: the switch, and for 방해 금지 the hours.
struct NotificationKindView: View {
    let kind: NotificationKind
    @AppStorage private var isOn: Bool

    init(kind: NotificationKind) {
        self.kind = kind
        _isOn = AppStorage(wrappedValue: kind.defaultOn, kind.storageKey)
    }

    var body: some View {
        List {
            Section { Toggle(kind.title, isOn: $isOn).font(Theme.Typo.rowTitle) }.onAllCardRow()
        }
        .onAllGroupedScreen()
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct QuietHoursView: View {
    @AppStorage(QuietHours.enabledKey) private var enabled = false
    @AppStorage(QuietHours.startKey) private var start = QuietHours.defaultStart
    @AppStorage(QuietHours.endKey) private var end = QuietHours.defaultEnd

    var body: some View {
        List {
            Section { Toggle("방해 금지", isOn: $enabled).font(Theme.Typo.rowTitle) }.onAllCardRow()
            if enabled {
                Section {
                    DatePicker("시작", selection: binding($start), displayedComponents: .hourAndMinute)
                    DatePicker("끝", selection: binding($end), displayedComponents: .hourAndMinute)
                }
                .onAllCardRow()
            }
        }
        .onAllGroupedScreen()
        .navigationTitle("방해 금지")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func binding(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60, second: 0, of: Date()) ?? Date() },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }
}
