import NEOBudgetCalendar
import SwiftUI

/// The day timeline: header, week strip, all-day row, the time grid and a one-line day summary.
struct DayTimelineScreen: View {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: TimelineSelection?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(model.isDemo ? "데모" : "")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(model.isDemo ? .visible : .hidden, for: .navigationBar)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, model.phase == .ready { Task { await model.reload() } }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView("일정을 불러오는 중").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .needsAccess:
            StatusView(
                symbol: "calendar.badge.clock",
                title: "캘린더를 연결하세요",
                message: "OnAll은 기기 캘린더의 일정을 읽어 타임라인에 보여줍니다. 일정은 캘린더에 그대로 남고 OnAll은 읽기와 변경 요청만 합니다.",
                actionTitle: "캘린더 접근 허용"
            ) { await model.requestAccess() }
        case .denied:
            StatusView(
                symbol: "lock.slash",
                title: "캘린더 접근이 꺼져 있습니다",
                message: "설정 > OnAll에서 캘린더 접근을 '전체 접근'으로 바꿔 주세요.",
                actionTitle: "설정 열기"
            ) { await openSettings() }
        case let .failed(message):
            StatusView(symbol: "exclamationmark.triangle", title: message, message: "잠시 후 다시 시도해 주세요.", actionTitle: "다시 시도") {
                await model.reload()
            }
        case .ready:
            if let timeline = model.timeline { ready(timeline) }
        }
    }

    private func ready(_ timeline: DayTimeline) -> some View {
        VStack(spacing: 0) {
            DayHeader(model: model)
            WeekStripView(week: model.week, selected: model.selectedDay) { day in Task { await model.select(day) } }
            Divider()
            if !timeline.allDay.isEmpty {
                AllDayRow(items: timeline.allDay) { selection = .allDay($0) }
                Divider()
            }
            TimelineGridView(timeline: timeline, zone: model.dayZone, isToday: model.isToday) { selection = $0 }
            Divider()
            SummaryBar(summary: timeline.summary)
        }
        .sheet(item: $selection) { item in
            EventDetailView(selection: item, zoneIdentifier: timeline.timeZoneIdentifier)
                .presentationDetents([.medium, .large])
        }
    }

    private func openSettings() async {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        await UIApplication.shared.open(url)
    }
}

private struct StatusView: View {
    let symbol: String
    let title: String
    let message: String
    let actionTitle: String
    let action: () async -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol).font(.system(size: 44)).foregroundStyle(.secondary)
            Text(title).font(.title3.bold()).multilineTextAlignment(.center)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(actionTitle) { Task { await action() } }.buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DayHeader: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Text(Formatting.dayTitle(model.selectedDay)).font(.title2.bold())
            Spacer()
            Button("오늘") { Task { await model.goToday() } }
                .buttonStyle(.bordered).disabled(model.isToday)
            Button { Task { await model.shift(days: -1) } } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("이전 날")
            Button { Task { await model.shift(days: 1) } } label: { Image(systemName: "chevron.right") }
                .accessibilityLabel("다음 날")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct SummaryBar: View {
    let summary: DaySummary

    var body: some View {
        HStack(spacing: 14) {
            Label("\(summary.eventCount + summary.allDayCount)", systemImage: "calendar")
            if summary.unlinkedTransactionCount > 0 {
                Label("활동 없는 지출 \(summary.unlinkedTransactionCount)건", systemImage: "creditcard")
            }
            Spacer()
            ForEach(summary.totals, id: \.currency) { total in
                let spent = total.linkedNetMinorUnits + total.unlinkedNetMinorUnits
                Text(Formatting.money(spent, currency: total.currency) + (total.uncertainNetMinorUnits > 0 ? " + 미정" : ""))
                    .font(.subheadline.monospacedDigit().bold())
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}
