import NEOBudgetCalendar
import SwiftUI

/// The day timeline: header, week strip, all-day row, the time grid and a one-line day summary.
struct DayTimelineScreen: View {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: TimelineSelection?
    @State private var infoEvent: CalendarEventKey?

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
            if let editor = model.editor {
                TimelineGridView(timeline: timeline, zone: model.dayZone, isToday: model.isToday, editor: editor, onSelect: { selection = $0 }, onEditInfo: { infoEvent = $0.eventKey })
                    .overlay(alignment: .topTrailing) { if editor.isEditing && editor.mode == .idle { DonePill(editor: editor) } }
            }
            Divider()
            SummaryBar(summary: timeline.summary)
        }
        .sheet(item: $selection) { item in
            EventDetailView(selection: item, zoneIdentifier: timeline.timeZoneIdentifier)
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $infoEvent) { key in EventActivitySheet(model: model, eventKey: key).presentationDetents([.medium, .large]) }
        .modifier(EditingPresentations(editor: model.editor, calendars: model.calendars, zoneIdentifier: timeline.timeZoneIdentifier))
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

/// Banner, recurring-scope dialog and new-event sheet for the timeline editor. Each is driven by the editor's mode,
/// so dismissing any of them without choosing rolls the preview back.
private struct EditingPresentations: ViewModifier {
    let editor: TimelineEditor?
    let calendars: [CalendarDescriptor]
    let zoneIdentifier: String

    func body(content: Content) -> some View {
        guard let editor else { return AnyView(content) }
        let scopeBinding = Binding(
            get: { editor.mode == .choosingScope },
            set: { if !$0 && editor.mode == .choosingScope { editor.cancel() } }
        )
        let nameBinding = Binding(
            get: { editor.mode == .namingEvent },
            set: { if !$0 && editor.mode == .namingEvent { editor.cancel() } }
        )
        return AnyView(
            content
                .overlay(alignment: .top) {
                    if let feedback = editor.feedback {
                        FeedbackBanner(feedback: feedback, retry: { editor.retry() }, dismiss: { editor.feedback = nil })
                            .padding(.top, 8)
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .task(id: feedback.id) {
                                // A message offering "다시 시도" stays until the user acts on it or dismisses it.
                                guard !feedback.canRetry else { return }
                                try? await Task.sleep(for: .seconds(6))
                                if editor.feedback?.id == feedback.id { editor.feedback = nil }
                            }
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: editor.feedback?.id)
                .confirmationDialog("반복 일정", isPresented: scopeBinding, titleVisibility: .visible) {
                    if editor.scopeOptions.contains(.thisOccurrence) { Button("이 일정만") { editor.chooseScope(.thisOccurrence) } }
                    if editor.scopeOptions.contains(.allInSeries) { Button("전체 일정") { editor.chooseScope(.allInSeries) } }
                    Button("취소", role: .cancel) { editor.chooseScope(nil) }
                } message: {
                    Text("이 변경을 어디까지 적용할까요?")
                }
                .sheet(isPresented: nameBinding) {
                    if let preview = editor.preview {
                        NewEventSheet(
                            range: preview.range, zoneIdentifier: zoneIdentifier, calendars: calendars,
                            onSave: { title, calendarID in editor.confirmCreate(title: title, calendarID: calendarID) },
                            onCancel: { editor.cancel() }
                        )
                        .presentationDetents([.medium])
                    }
                }
        )
    }
}

/// Leaves edit mode: the day folds back up. Tapping empty time does the same.
private struct DonePill: View {
    let editor: TimelineEditor

    var body: some View {
        Button { editor.exitEditMode() } label: {
            Label("완료", systemImage: "checkmark").font(.footnote.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.thinMaterial, in: Capsule())
        }
        .padding(10)
        .accessibilityLabel("편집 끝내기")
        .transition(.opacity)
    }
}
