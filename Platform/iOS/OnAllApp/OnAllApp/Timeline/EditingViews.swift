import NEOBudgetCalendar
import SwiftUI

/// Tells the user a change was not saved. The preview has already been rolled back when this shows.
struct FeedbackBanner: View {
    let feedback: EditFeedback
    let retry: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: feedback.tone == .error ? "exclamationmark.triangle.fill" : "info.circle.fill")
            Text(feedback.message).font(.footnote).multilineTextAlignment(.leading)
            Spacer(minLength: 4)
            if feedback.canRetry { Button("다시 시도", action: retry).font(.footnote.bold()) }
            Button(action: dismiss) { Image(systemName: "xmark") }.accessibilityLabel("닫기")
        }
        .padding(12)
        .foregroundStyle(.white)
        .background(feedback.tone == .error ? Color.red : Color.blue, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .shadow(radius: 6, y: 2)
        .accessibilityElement(children: .combine)
    }
}

/// Title and calendar for a new event whose time was just dragged out. Cancelling (or swiping the sheet away)
/// discards the preview; nothing is written until Save.
struct NewEventSheet: View {
    let range: TimedRange
    let zoneIdentifier: String
    let calendars: [CalendarDescriptor]
    let onSave: (String, CalendarID) -> Void
    let onCancel: () -> Void

    @State private var title = ""
    @State private var calendarID: CalendarID
    @FocusState private var focused: Bool

    init(
        range: TimedRange, zoneIdentifier: String, calendars: [CalendarDescriptor],
        onSave: @escaping (String, CalendarID) -> Void, onCancel: @escaping () -> Void
    ) {
        self.range = range
        self.zoneIdentifier = zoneIdentifier
        self.calendars = calendars.filter(\.isWritable)
        self.onSave = onSave
        self.onCancel = onCancel
        _calendarID = State(initialValue: calendars.first(where: \.isWritable)?.id ?? CalendarID(rawValue: ""))
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("제목", text: $title).focused($focused).submitLabel(.done)
                LabeledContent("시간", value: Formatting.timeRange(range.startUnixMilliseconds, range.endUnixMilliseconds, zoneIdentifier: zoneIdentifier))
                Picker("캘린더", selection: $calendarID) {
                    ForEach(calendars, id: \.id) { calendar in Text(calendar.title).tag(calendar.id) }
                }
            }
            .navigationTitle("새 일정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) { Button("저장") { onSave(title, calendarID) }.disabled(calendars.isEmpty) }
            }
            .onAppear { focused = true }
        }
    }
}
