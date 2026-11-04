import NEOBudgetCalendar
import SwiftUI

/// Makes an event (design-v2 openend-v1, "만들기"). A time written in the title ("18시 저녁 약속") is offered as one "18:00 – 미정" button; pressing it
/// takes the time out of the title and sets the start. Saved without it, the event is all-day. A start with no end is saved as 종료 미정
/// (`NewEventInput.plan`): there is no switch, an empty end is the open end.
struct EventCreateSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var calendarID: CalendarID?
    @State private var day: Date
    @State private var startMinute: Int?
    @State private var endMinute: Int?
    @State private var failure: String?
    @State private var isSaving = false
    @FocusState private var titleFocused: Bool

    init(model: AppModel) {
        self.model = model
        var parts = DateComponents()
        parts.year = model.selectedDay.year; parts.month = model.selectedDay.month; parts.day = model.selectedDay.day
        _day = State(initialValue: Calendar.current.date(from: parts) ?? Date())
    }

    private var writable: [CalendarDescriptor] { model.calendars.filter(\.isWritable) }
    private var suggestion: TitleTimeSuggestion? { startMinute == nil ? TitleTimeSuggestion.find(in: title) : nil }
    private var canSave: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty && (calendarID ?? writable.first?.id) != nil && !isSaving }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                TextField("제목", text: $title)
                    .font(Theme.Typo.sheetTitle)
                    .focused($titleFocused)
                    .submitLabel(.done)
                Button("저장") { save() }
                    .buttonStyle(PrimaryButtonStyle(height: 36))
                    .fixedSize()
                    .disabled(!canSave)
            }
            if writable.count > 1 { calendarChips }
            if let suggestion {
                Button { take(suggestion) } label: {
                    Text(suggestion.label).font(Theme.Typo.label.weight(.semibold)).foregroundStyle(Theme.accentStrong)
                        .padding(.horizontal, Theme.Space.m).padding(.vertical, 6)
                        .background(Theme.accentSoft, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            VStack(spacing: 0) {
                row("날짜") { DatePicker("", selection: $day, displayedComponents: .date).labelsHidden() }
                row("종일") { Toggle("", isOn: allDay).labelsHidden().tint(Theme.accent) }
                if startMinute != nil {
                    row("시작") { DatePicker("", selection: time($startMinute, fallback: 9 * 60), displayedComponents: .hourAndMinute).labelsHidden() }
                    row("종료") {
                        if endMinute == nil {
                            Button("추가") { endMinute = min((startMinute ?? 0) + 60, 23 * 60 + 59) }.foregroundStyle(Theme.textTertiary)
                        } else {
                            HStack {
                                DatePicker("", selection: time($endMinute, fallback: 10 * 60), displayedComponents: .hourAndMinute).labelsHidden()
                                Button { endMinute = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.disabled) }
                                    .accessibilityLabel("종료 시각 지우기")
                            }
                        }
                    }
                }
            }
            if let failure { Text(failure).font(Theme.Typo.caption).foregroundStyle(Theme.danger) }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.xl)
        .onAppear { titleFocused = true; calendarID = calendarID ?? writable.first?.id }
        .onAllSheet(detents: [.medium, .large])
    }

    private var calendarChips: some View {
        FlowLayout(spacing: Theme.Space.s) {
            ForEach(writable, id: \.id) { calendar in
                let chosen = (calendarID ?? writable.first?.id) == calendar.id
                Button { calendarID = calendar.id } label: {
                    HStack(spacing: 6) {
                        Circle().fill(Color(hex: calendar.colorHex) ?? Theme.accent).frame(width: 8, height: 8)
                        Text(calendar.title).font(Theme.Typo.label)
                    }
                    .foregroundStyle(chosen ? Theme.accentStrong : Theme.textSecondary)
                    .padding(.horizontal, Theme.Space.m).padding(.vertical, 6)
                    .background(chosen ? Theme.accentSoft : Theme.fill, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func row<Trailing: View>(_ label: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Text(label).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textSecondary)
            Spacer()
            trailing()
        }
        .frame(minHeight: 48)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }

    /// 종일 is "no start": switching it off starts at 9:00, on clears the start and end.
    private var allDay: Binding<Bool> {
        Binding(
            get: { startMinute == nil },
            set: { on in
                if on { startMinute = nil; endMinute = nil } else { startMinute = 9 * 60 }
            }
        )
    }

    private func time(_ minute: Binding<Int?>, fallback: Int) -> Binding<Date> {
        Binding(
            get: {
                let m = minute.wrappedValue ?? fallback
                return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: day) ?? day
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                minute.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }

    private func take(_ suggestion: TitleTimeSuggestion) {
        title = suggestion.strippedTitle
        startMinute = suggestion.minuteOfDay
    }

    private func save() {
        guard let calendarID = calendarID ?? writable.first?.id else { return }
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: day)
        guard let localDay = try? LocalDate(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1) else { return }
        isSaving = true
        let input = NewEventInput(title: title, calendarID: calendarID, day: localDay, startMinute: startMinute, endMinute: endMinute)
        Task {
            let message = await model.createEvent(input)
            isSaving = false
            if let message { failure = message } else { dismiss() }
        }
    }
}
