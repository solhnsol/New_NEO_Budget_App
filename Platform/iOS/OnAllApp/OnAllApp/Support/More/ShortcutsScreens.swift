import NEOBudgetCore
import SwiftUI

/// 단축어: whether the Shortcut is delivering, the received-notification history, the handling rules, and which apps to take notifications from.
struct ShortcutsScreen: View {
    let model: AppModel
    @State private var items: [InboxItem]?
    @State private var apps: [String: Bool] = [:]

    private static let sourceApps: [(name: String, icon: String, tone: STone)] = [
        ("카카오뱅크", "bank", .orange), ("토스", "bank", .accent), ("신한카드", "card", .teal), ("교통카드", "card", .green),
    ]

    var body: some View {
        SettingsPage(title: "단축어") {
            HStack(spacing: 10) {
                STile(icon: "bolt", tone: .orange)
                VStack(alignment: .leading, spacing: 0) {
                    Text("알림 받기").font(Theme.Typo.button).foregroundStyle(Theme.textPrimary)
                    Text(lastReceived).font(Theme.Typo.label).foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 0)
                if items?.isEmpty == false {
                    Text("연결됨").font(.onAll(size: 12, weight: .semibold)).foregroundStyle(Theme.accentStrong)
                        .padding(.horizontal, 10).frame(height: 28).background(Theme.accentSoft, in: Capsule())
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12).frame(minHeight: 60)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .padding(.horizontal, 16).padding(.top, 12)
            SCard {
                SLink(row: SRow(icon: "list", tone: .orange, title: "받은 알림 내역", value: items.map { "\($0.count)건" }, chevron: true)) { IntakeInboxView(model: model) }
                SLink(row: SRow(icon: "file", tone: .purple, title: "알림 처리 규칙", value: "\(NotificationRule.samples.count)개", chevron: true)) { RulesScreen() }
            }
            .padding(.top, 12)
            SSection(title: "받을 앱") {
                ForEach(Self.sourceApps, id: \.name) { app in
                    SToggleRow(icon: app.icon, tone: app.tone, title: app.name, isOn: Binding(get: { apps[app.name] ?? true }, set: { apps[app.name] = $0 }))
                }
            }
            SButton(title: "단축어 추가하기", light: true)
        }
        .task(id: model.dataGeneration) { items = await model.inbox() }
    }

    private var lastReceived: String {
        guard let item = items?.first else { return "아직 받은 알림이 없어요" }
        let time = item.notification.notificationAtUnixMilliseconds ?? item.notification.capturedAtUnixMilliseconds
        return "마지막 수신 " + Formatting.shortDate(time, zoneIdentifier: model.dayZone.identifier) + " " + Formatting.time(time, zoneIdentifier: model.dayZone.identifier)
    }
}

/// A notification handling rule as the mockup shows it. Looks only: the app has no rule engine yet, so these are fixed examples.
struct NotificationRule: Identifiable {
    let id = UUID()
    let name: String
    let sub: String
    let count: String
    var on: Bool
    let group: String

    static let samples: [NotificationRule] = [
        .init(name: "카드 승인", sub: "신한카드 · 지출", count: "112건", on: true, group: "카드"),
        .init(name: "카드 취소", sub: "신한카드 · 지출 취소", count: "6건", on: true, group: "카드"),
        .init(name: "해외 승인", sub: "삼성카드 · 지출", count: "2건", on: false, group: "카드"),
        .init(name: "입금", sub: "카카오뱅크 · 수입", count: "48건", on: true, group: "통장"),
        .init(name: "출금", sub: "토스 · 지출", count: "71건", on: true, group: "통장"),
        .init(name: "입금 · 정산 후보", sub: "카카오뱅크 · 정산 확인", count: "19건", on: true, group: "통장"),
        .init(name: "교통 승차", sub: "교통카드 · 지출", count: "43건", on: true, group: "기타"),
        .init(name: "광고 문자 무시", sub: "문구에 \"광고\" 포함 · 무시", count: "11건", on: true, group: "기타"),
    ]
}

/// 알림 처리 규칙.
struct RulesScreen: View {
    @State private var rules = NotificationRule.samples
    @State private var filter = 0
    @State private var adding = false

    var body: some View {
        SettingsPage(title: "알림 처리 규칙", action: ("추가", { adding = true })) {
            SChipRow(titles: ["전체 \(rules.count)", "지출", "수입", "무시"], selection: $filter)
            ForEach(["카드", "통장", "기타"], id: \.self) { group in
                SSection(title: group) {
                    ForEach($rules.filter { $0.wrappedValue.group == group }) { $rule in
                        HStack(spacing: 0) {
                            NavigationLink { RuleEditScreen(rule: rule, sample: nil) } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(rule.name).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary)
                                        Text(rule.sub).font(Theme.Typo.label).foregroundStyle(Theme.textTertiary)
                                    }
                                    Spacer(minLength: 8)
                                    Text(rule.count).font(.onAll(size: 15)).foregroundStyle(Theme.textTertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.onAllRow)
                            Toggle(rule.name, isOn: $rule.on).labelsHidden().toggleStyle(SToggleStyle()).padding(.leading, 12)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 8).frame(minHeight: 52)
                        .rowDivider(inset: 16)
                    }
                }
            }
        }
        .navigationDestination(isPresented: $adding) { RuleEditScreen(rule: nil, sample: nil) }
    }
}

/// 규칙 수정 / 새 규칙. Looks only, like the list.
struct RuleEditScreen: View {
    let rule: NotificationRule?
    let sample: String?
    @Environment(\.dismiss) private var dismiss
    @State private var kind = 0

    var body: some View {
        SettingsPage(title: rule == nil ? "새 규칙" : "규칙 수정", action: ("저장", { dismiss() })) {
            SSection(title: "이름") { SField(label: rule?.name ?? "규칙 이름", value: rule?.name ?? "") }
            SSection(title: "이런 알림이 오면") {
                SField(label: "받은 앱", value: "신한카드")
                SField(label: "문구에 포함", value: "승인")
                SField(label: "문구에 없어야 함", value: "취소")
            }
            SSection(title: "이렇게 읽어요") {
                SField(label: "금액", value: "\"승인\" 뒤 숫자")
                SField(label: "가맹점", value: "시각 뒤 마지막 문구")
            }
            SSection(title: "이렇게 기록해요") {
                SControlRow(title: "종류") { SSegment(options: ["지출", "수입"], selection: $kind).frame(width: 150) }
                SField(label: "분류", value: "가맹점 이름으로 자동")
            }
            SSection(title: "시험해 보기") {
                Text(sample ?? "[Web발신] 신한카드(4821) 승인 홍*동 4,500원 일시불 11/03 09:12 스타벅스 서울역점")
                    .font(.onAll(size: 14)).foregroundStyle(Theme.textSecondary).lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .background(Theme.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(16)
                SRow(title: "지출 · 스타벅스 서울역점") {
                    Text("−4,500원").font(Theme.Typo.amount).foregroundStyle(Theme.accent)
                }
            }
        }
    }
}
