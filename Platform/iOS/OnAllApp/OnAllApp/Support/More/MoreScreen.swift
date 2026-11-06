import NEOBudgetCalendar
import SwiftUI

/// 더보기: the tab's one screen (design-v2/polish/settings-v5.html, 더보기).
struct MoreScreen: View {
    let model: AppModel
    @Environment(\.switchAppMode) private var switchAppMode
    @State private var confirming: AppMode?
    @State private var openKind: NotificationKind?
    @State private var accountCount: Int?
    @State private var inboxCount: Int?
    @AppStorage(SurplusSetting.key) private var surplusRaw = SurplusTreatment.income.rawValue
    @AppStorage(QuietHours.enabledKey) private var quietEnabled = false
    @AppStorage(QuietHours.startKey) private var quietStart = QuietHours.defaultStart
    @AppStorage(QuietHours.endKey) private var quietEnd = QuietHours.defaultEnd

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("더보기").font(Theme.Typo.h1).tracking(-0.5).foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 6)
                ScrollView {
                    VStack(spacing: 0) {
                        SCard {
                            SSegment(options: ["둘러보기", "내 데이터"], selection: modeIndex).padding(.horizontal, 16).padding(.vertical, 12)
                            SRow(title: "정산보다 더 받은 돈") {
                                SSegment(options: ["수입", "차감"], selection: surplusIndex, small: true).frame(width: 150)
                            }
                        }
                        .padding(.top, 12)
                        SSection(title: "데이터") {
                            SLink(row: SRow(icon: "bolt", tone: .orange, title: "단축어", value: model.isDemo ? nil : "연결됨", chevron: true)) { ShortcutsScreen(model: model) }
                            SLink(row: SRow(icon: "down", tone: .green, title: "가져오기·내보내기", chevron: true)) { DataTransferScreen(model: model) }
                        }
                        SSection(title: "알림") {
                            ForEach(NotificationKind.allCases) { kind in NotificationToggleRow(kind: kind) { openKind = kind } }
                            SLink(row: SRow(icon: "bell", tone: .neutral, title: "방해 금지", value: quietEnabled ? QuietHours.summary(start: quietStart, end: quietEnd) : "꺼짐", chevron: true)) { QuietHoursScreen() }
                        }
                        SSection(title: "가계부") {
                            SLink(row: SRow(icon: "cal", title: "캘린더", value: "\(model.calendars.count)개", chevron: true)) { CalendarSettingsView(model: model) }
                            SLink(row: SRow(icon: "tag", tone: .purple, title: "분류 규칙", value: "\(model.transactionOverrides.rules.count)개", chevron: true)) { TransactionRulesView(model: model) }
                            SLink(row: SRow(icon: "card", tone: .teal, title: "계좌·카드", value: accountCount.map { "\($0)개" }, chevron: true)) {
                                AccountsView(model: model).navigationTitle("계좌·카드").navigationBarTitleDisplayMode(.inline)
                            }
                            SLink(row: SRow(icon: "wallet", tone: .green, title: "예산", value: "월 120만원", chevron: true)) { BudgetScreen() }
                            SLink(row: SRow(icon: "split", tone: .neutral, title: "정산 설정", chevron: true)) { SettlementSettingsScreen() }
                        }
                    }
                    .padding(.bottom, Theme.Space.xxl)
                }
            }
            .background(Theme.background)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $openKind) { NotificationKindScreen(model: model, kind: $0) }
        }
        .task(id: model.dataGeneration) {
            accountCount = await model.registeredAccounts().count
            inboxCount = await model.inbox().count
        }
        .alert("내 데이터로 바꿀까요?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            Button("바꾸기") { if let mode = confirming { switchAppMode(mode) } }
            Button("취소", role: .cancel) {}
        } message: {
            Text("캘린더 접근을 요청할 수 있어요. 예시 데이터는 따로 보관돼서 언제든 다시 볼 수 있어요.")
        }
    }

    private var modeIndex: Binding<Int> {
        Binding(
            get: { model.isDemo ? 0 : 1 },
            set: { index in
                guard index != (model.isDemo ? 0 : 1) else { return }
                if index == 1 { confirming = .live } else { switchAppMode(.demo) }
            }
        )
    }

    private var surplusIndex: Binding<Int> {
        Binding(
            get: { surplusRaw == SurplusTreatment.income.rawValue ? 0 : 1 },
            set: { surplusRaw = ($0 == 0 ? SurplusTreatment.income : SurplusTreatment.reduceSpending).rawValue }
        )
    }
}

/// A notification type on the main screen: its icon and name open the detail screen, the switch turns it on or off.
private struct NotificationToggleRow: View {
    let kind: NotificationKind
    let open: () -> Void
    @AppStorage private var isOn: Bool

    init(kind: NotificationKind, open: @escaping () -> Void) {
        self.kind = kind
        self.open = open
        _isOn = AppStorage(wrappedValue: kind.defaultOn, kind.storageKey)
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: open) {
                HStack(spacing: 12) {
                    STile(icon: kind.icon, tone: kind.tone)
                    Text(kind.title).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.onAllRow)
            Toggle(kind.title, isOn: $isOn).labelsHidden().toggleStyle(SToggleStyle())
            Button(action: open) { LineIcon(name: "chev", size: 18).foregroundStyle(Theme.disabled) }
                .buttonStyle(.plain).padding(.leading, -4).accessibilityHidden(true)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(minHeight: 52)
        .rowDivider(inset: 64)
    }
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

    var icon: String {
        switch self {
        case .settlement: "split"
        case .budget: "wallet"
        case .eventSpending: "cal"
        case .categoryRequest: "tag"
        case .recurring: "repeat"
        }
    }

    var tone: STone {
        switch self {
        case .settlement: .pink
        case .budget: .green
        case .eventSpending: .accent
        case .categoryRequest: .purple
        case .recurring: .orange
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

struct QuietHoursScreen: View {
    @AppStorage(QuietHours.enabledKey) private var enabled = false
    @AppStorage(QuietHours.startKey) private var start = QuietHours.defaultStart
    @AppStorage(QuietHours.endKey) private var end = QuietHours.defaultEnd

    var body: some View {
        SettingsPage(title: "방해 금지") {
            SSection { SToggleRow(title: "방해 금지", isOn: $enabled) }
            if enabled {
                SSection(title: "시간") {
                    SRow(title: "시작") { DatePicker("시작", selection: binding($start), displayedComponents: .hourAndMinute).labelsHidden() }
                    SRow(title: "끝") { DatePicker("끝", selection: binding($end), displayedComponents: .hourAndMinute).labelsHidden() }
                }
            }
        }
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

/// One notification type's own screen (settings-v5 D1–D4). Only the master switch is stored; the options below it are looks until the notifications exist.
struct NotificationKindScreen: View {
    let model: AppModel
    let kind: NotificationKind
    @AppStorage private var isOn: Bool
    @State private var flags: [String: Bool] = [:]
    @State private var days = 14
    @State private var minutes = 30
    @State private var repeatEvery = 0
    @State private var delivery = 0
    @State private var calendars: Set<CalendarID> = []

    init(model: AppModel, kind: NotificationKind) {
        self.model = model
        self.kind = kind
        _isOn = AppStorage(wrappedValue: kind.defaultOn, kind.storageKey)
    }

    private func flag(_ title: String, _ on: Bool = true) -> Binding<Bool> {
        Binding(get: { flags[title] ?? on }, set: { flags[title] = $0 })
    }

    private func toggle(_ title: String, _ on: Bool = true) -> some View { SToggleRow(title: title, isOn: flag(title, on)) }

    private func value(_ title: String, _ value: String) -> some View { SRow(title: title, value: value) }

    var body: some View {
        SettingsPage(title: kind.title) {
            SSection { SToggleRow(title: kind.title, isOn: $isOn) }
            switch kind {
            case .settlement:
                SSection(title: "보낼 때") { toggle("입금이 들어왔을 때"); toggle("입금이 부족할 때"); toggle("기한이 지났을 때") }
                SSection(title: "기한") {
                    SControlRow(title: "지연으로 보는 기간") { SStepper(value: $days, unit: "일") }
                    SControlRow(title: "다시 알림") { SSegment(options: ["매일", "3일 마다"], selection: $repeatEvery).frame(width: 190) }
                }
                SSection(title: "시간") { value("알림 시각", "오전 9:00") }
            case .budget:
                SSection(title: "사용률이 넘을 때") { toggle("50%", false); toggle("80%"); toggle("100%") }
                SSection(title: "추가") { toggle("한 달 속도가 빠를 때"); toggle("분류별 예산 초과") }
                SSection(title: "시간") { value("알림 시각", "지출이 생길 때") }
            case .eventSpending:
                SSection(title: "보낼 때") {
                    SControlRow(title: "일정이 끝나고") { SStepper(value: $minutes, unit: "분") }
                    toggle("쓴 돈이 있는 일정만"); toggle("연결 안 된 지출이 있을 때")
                }
                SSection(title: "받을 캘린더") {
                    ForEach(model.calendars, id: \.id) { calendar in
                        let color = Color(hex: calendar.colorHex) ?? Theme.accent
                        SRow(dot: color, title: calendar.title) {
                            Toggle(calendar.title, isOn: Binding(
                                get: { !calendars.contains(calendar.id) },
                                set: { if $0 { calendars.remove(calendar.id) } else { calendars.insert(calendar.id) } }
                            )).labelsHidden().toggleStyle(SToggleStyle())
                        }
                    }
                }
            case .categoryRequest:
                SSection(title: "받는 방식") { SControlRow(title: "새 거래가 들어오면") { SSegment(options: ["바로", "모아서"], selection: $delivery).frame(width: 150) } }
                SSection(title: "대상") { toggle("분류를 못 찾았을 때"); toggle("확실하지 않을 때"); toggle("큰 금액만", false) }
                SSection(title: "시간") { value("모아서 보낼 시각", "오후 9:00") }
            case .recurring:
                SSection(title: "보낼 때") { toggle("결제 하루 전"); toggle("금액이 달라졌을 때") }
            }
        }
    }
}

/// A calendar's color on a soft tile of the same color (12%), as a dot.
struct SDotTile: View {
    let color: Color

    var body: some View {
        Circle().fill(color).frame(width: 12, height: 12)
            .frame(width: 36, height: 36)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
