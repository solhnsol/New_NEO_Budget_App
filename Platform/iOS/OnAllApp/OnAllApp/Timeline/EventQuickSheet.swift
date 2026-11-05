import NEOBudgetCalendar
import SwiftUI

/// The small sheet an event opens from the calendar (the design's `openEv`): its name with a 확인 button that lights up once something changed, the
/// date and both times as three pills (each opens the system picker), and the calendar's chip. Under the fold, pulled up: what was spent in it, the
/// event's info and 삭제.
struct EventQuickSheet: View {
    let block: EventBlock
    let model: AppModel
    var onEditInfo: (EventBlock) -> Void = { _ in }
    var onSettle: (EventBlock) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var start: Date
    @State private var end: Date
    @State private var failure: String?
    /// Set once the changes are written, so closing the sheet does not write them again.
    @State private var saved = false
    @State private var scopeChoices: [RecurrenceScope] = []
    @State private var pendingRequest: EventSaveRequest?
    @State private var confirmsDelete = false
    @State private var detent = PresentationDetent.height(Self.quickHeight)
    @FocusState private var titleFocused: Bool

    static let quickHeight: CGFloat = 126

    init(block: EventBlock, model: AppModel, onEditInfo: @escaping (EventBlock) -> Void = { _ in }, onSettle: @escaping (EventBlock) -> Void = { _ in }) {
        self.block = block
        self.model = model
        self.onEditInfo = onEditInfo
        self.onSettle = onSettle
        _title = State(initialValue: block.title)
        _start = State(initialValue: Date(timeIntervalSince1970: Double(block.startUnixMilliseconds) / 1000))
        _end = State(initialValue: Date(timeIntervalSince1970: Double(block.endUnixMilliseconds) / 1000))
    }

    private var zone: TimeZone { TimeZone(identifier: model.dayZone.identifier) ?? .current }
    private var cleanTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var originalStart: Date { Date(timeIntervalSince1970: Double(block.startUnixMilliseconds) / 1000) }
    private var originalEnd: Date { Date(timeIntervalSince1970: Double(block.endUnixMilliseconds) / 1000) }
    private var dirty: Bool { (!cleanTitle.isEmpty && cleanTitle != block.title) || start != originalStart || end != originalEnd }
    private var editable: Bool { block.isEditable }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Theme.Space.s) {
                    TextField("제목", text: $title).font(Theme.Typo.sheetTitle).foregroundStyle(Theme.textPrimary)
                        .focused($titleFocused).submitLabel(.done).onSubmit { titleFocused = false }.disabled(!editable)
                    Button { Task { await save(nil) } } label: {
                        Text("확인").font(Theme.Typo.smallButton).foregroundStyle(.white)
                            .padding(.horizontal, Theme.Space.l).frame(height: Theme.smallButtonHeight)
                            .background(dirty ? Theme.accent : Theme.disabled, in: RoundedRectangle(cornerRadius: Theme.Radius.smallButton, style: .continuous))
                    }
                    .buttonStyle(.plain).disabled(!dirty)
                }
                .padding(.top, Theme.Space.xl)
                HStack(spacing: Theme.Space.s) {
                    pill(Self.dayText(start, zone), hasDate: true)
                    pill(Self.clock(start, zone), time: timeBinding($start, isStart: true))
                    Text("–").foregroundStyle(Theme.disabled)
                    pill(Self.clock(end, zone), time: timeBinding($end, isStart: false))
                    Spacer(minLength: 0)
                }
                .padding(.top, Theme.Space.m)
                calendarChip.padding(.top, Theme.Space.m)
                if let failure { Text(failure).font(Theme.Typo.caption).foregroundStyle(Theme.danger).padding(.top, Theme.Space.s) }
                below
            }
            .padding(.horizontal, Theme.Space.xl).padding(.bottom, Theme.Space.l)
        }
        .scrollIndicators(.hidden)
        .background(Theme.surface)
        .tint(Theme.accent)
        .environment(\.timeZone, zone)
        // Closing the sheet any other way than 확인 (a swipe down, a tap outside) keeps what was changed: it is written then, so the day shows it at once.
        .onDisappear {
            guard dirty, !saved else { return }
            let request = makeRequest(scope: block.isRecurringInstance ? .thisOccurrence : nil)
            Task { _ = await model.save(request) }
        }
        .presentationDetents([.height(Self.quickHeight), .large], selection: $detent)
        .presentationCornerRadius(Theme.Radius.sheet)
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.surface)
        .confirmationDialog("이 일정을 지울까요?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("일정 삭제", role: .destructive) { Task { await delete() } }
            Button("취소", role: .cancel) {}
        }
        .confirmationDialog("반복 일정", isPresented: Binding(get: { !scopeChoices.isEmpty }, set: { if !$0 { scopeChoices = [] } }), titleVisibility: .visible) {
            ForEach(scopeChoices, id: \.self) { scope in
                Button(scope == .thisOccurrence ? "이 일정만" : "전체 일정") { Task { await save(scope) } }
            }
            Button("취소", role: .cancel) {}
        } message: { Text("이 변경을 어디까지 적용할까요?") }
    }

    // MARK: Pieces

    /// A pill with the date or time in it and the system picker laid invisibly over it.
    private func pill(_ text: String, hasDate: Bool = false, time: Binding<Date>? = nil) -> some View {
        Text(text).font(.onAll(size: 15, weight: .medium).monospacedDigit()).foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, Theme.Space.m).frame(height: Theme.smallButtonHeight)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.Radius.smallButton, style: .continuous))
            .overlay {
                // The system picker over the pill, drawn clear: its tap opens the picker, the pill stays as designed.
                if editable {
                    if let time {
                        DatePicker("", selection: time, displayedComponents: .hourAndMinute).labelsHidden().datePickerStyle(.compact).colorMultiply(.clear)
                    } else if hasDate {
                        DatePicker("", selection: dayBinding, displayedComponents: .date).labelsHidden().datePickerStyle(.compact).colorMultiply(.clear)
                    }
                }
            }
    }

    /// A time picked in the system picker is only the clock part of what it hands back (it may carry today's date, not the event's): the hour and
    /// minute are put on the day the event is on. A start moved to or past the end pushes the end a quarter hour after it.
    private func timeBinding(_ binding: Binding<Date>, isStart: Bool) -> Binding<Date> {
        Binding(
            get: { binding.wrappedValue },
            set: { picked in
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = zone
                let clock = calendar.dateComponents([.hour, .minute], from: picked)
                // The day of the start is the event's day; an end that already runs into another day keeps its own day.
                let anchor = isStart ? start : end
                guard let moved = calendar.date(bySettingHour: clock.hour ?? 0, minute: clock.minute ?? 0, second: 0, of: anchor) else { return }
                binding.wrappedValue = moved
                if isStart, end <= moved { end = moved.addingTimeInterval(15 * 60) }
            }
        )
    }

    /// Changing the day moves both ends, keeping the times of day.
    private var dayBinding: Binding<Date> {
        Binding(
            get: { start },
            set: { picked in
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = zone
                let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: picked)).day ?? 0
                start = calendar.date(byAdding: .day, value: days, to: start) ?? start
                end = calendar.date(byAdding: .day, value: days, to: end) ?? end
            }
        )
    }

    /// The event's calendar. Moving an event to another calendar is not something the calendar commands do, so only its own is shown.
    private var calendarChip: some View {
        HStack(spacing: 6) {
            Circle().fill(Color(hex: block.calendarColorHex) ?? Theme.accent).frame(width: 8, height: 8)
            Text(block.calendarTitle ?? "캘린더").font(.onAll(size: 13, weight: .medium))
        }
        .foregroundStyle(Theme.accentStrong).padding(.horizontal, Theme.Space.m).frame(height: Theme.chipHeight)
        .background(Theme.accentSoft, in: Capsule())
    }

    @ViewBuilder
    private var below: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: Theme.Space.xl)
            if !block.allocations.isEmpty {
                ForEach(block.allocatedSpend, id: \.currency) { total in
                    Text(Formatting.grouped(total.knownMinorUnits) + "원").font(Theme.Typo.hero).foregroundStyle(Theme.accent).padding(.top, Theme.Space.s)
                }
                ForEach(block.allocations, id: \.allocationID) { item in
                    HStack(spacing: Theme.Space.s) {
                        Text(item.title ?? "거래").font(.onAll(size: 16, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Text(Formatting.clock24(item.occurredAtUnixMilliseconds, zoneIdentifier: model.dayZone.identifier)).font(.onAll(size: 12).monospacedDigit()).foregroundStyle(Theme.textTertiary)
                        Spacer(minLength: 0)
                        Text((item.flow == .refund ? "+" : "−") + Formatting.knowledge(item.allocatedAmount, currency: item.transactionAmount.currency))
                            .font(.onAll(size: 16, weight: item.flow == .refund ? .semibold : .medium).monospacedDigit())
                            .foregroundStyle(Theme.amountColor(isIncoming: item.flow == .refund))
                    }
                    .frame(minHeight: Theme.rowHeight)
                }
            }
            Button { onEditInfo(block) } label: { actionLabel("지출 연결과 일정 정보", color: Theme.accentStrong, fill: Theme.accentSoft) }
                .buttonStyle(.plain).padding(.top, Theme.Space.l)
            if block.activity != nil {
                Button { onSettle(block) } label: { actionLabel("정산", color: Theme.accentStrong, fill: Theme.accentSoft) }
                    .buttonStyle(.plain).padding(.top, Theme.Space.s)
            }
            Button { confirmsDelete = true } label: { actionLabel("일정 삭제", color: Theme.dangerStrong, fill: Theme.dangerSoft) }
                .buttonStyle(.plain).disabled(!editable).padding(.top, Theme.Space.s)
        }
    }

    private func actionLabel(_ text: String, color: Color, fill: Color) -> some View {
        Text(text).font(.onAll(size: 16, weight: .semibold)).foregroundStyle(color)
            .frame(maxWidth: .infinity, minHeight: Theme.primaryButtonHeight)
            .background(fill, in: RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
    }

    // MARK: Actions

    private func save(_ scope: RecurrenceScope?) async {
        titleFocused = false
        let request = makeRequest(scope: scope)
        switch await model.save(request) {
        case .saved, .unchanged: saved = true; dismiss()
        case let .needsScope(options): scopeChoices = options
        case .refused: failure = "저장하지 못했어요. 일정이 바뀌었을 수 있어요."
        case .failed: failure = "저장하지 못했어요. 잠시 뒤에 다시 해 주세요."
        case nil: failure = "저장하지 못했어요."
        }
    }

    private func makeRequest(scope: RecurrenceScope?) -> EventSaveRequest {
        EventSaveRequest(
            original: EventSaveOriginal(block: block), proposedStart: start, proposedEnd: max(end, start.addingTimeInterval(900)),
            proposedTitle: cleanTitle.isEmpty || cleanTitle == block.title ? nil : cleanTitle, scope: scope
        )
    }

    private func delete() async {
        let input = DeleteEventInput(
            target: EventTarget(key: block.eventKey, expectedRevisionToken: block.revisionToken), scope: block.isRecurringInstance ? .thisOccurrence : nil
        )
        switch await model.perform(.deleteEvent(input)) {
        case .applied?, .partiallyApplied?: dismiss()
        default: failure = "지우지 못했어요."
        }
    }

    private static func dayText(_ date: Date, _ zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR"); formatter.timeZone = zone; formatter.dateFormat = "M월 d일 E"
        return formatter.string(from: date)
    }

    private static func clock(_ date: Date, _ zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = zone; formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
