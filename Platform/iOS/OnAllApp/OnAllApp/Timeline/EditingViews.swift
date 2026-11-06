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
        .background(feedback.tone == .error ? Theme.danger : Theme.accent, in: RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
        .padding(.horizontal, 16)
        .shadow(radius: 6, y: 2)
        .accessibilityElement(children: .combine)
    }
}

/// Title and calendar for a new event whose time was just dragged out (design-v2 polish/create-v11, the small sheet). Swiping the sheet away
/// discards the preview; nothing is written until Save.
struct NewEventSheet: View {
    let range: TimedRange
    let zoneIdentifier: String
    let calendars: [CalendarDescriptor]
    let onSave: (String, CalendarID) -> Void
    let onCancel: () -> Void

    @State private var title = ""
    @State private var calendarID: CalendarID?
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
        _calendarID = State(initialValue: calendars.first(where: \.isWritable)?.id)
    }

    private var chosen: CalendarID? { calendarID ?? calendars.first?.id }
    private var canSave: Bool { chosen != nil && !title.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        PanelSheet(isOpen: .constant(false), canOpen: false, close: onCancel) {
            VStack(alignment: .leading, spacing: 0) {
                SheetTitleLine(canSave: canSave, save: save) {
                    SheetTitleField(text: $title, focus: $focused, submit: { if canSave { save() } })
                }
                if calendars.count > 1 { SheetCalendarChips(calendars: calendars, selection: $calendarID).padding(.top, Theme.Space.m) }
                SheetSummaryLine(parts: summaryParts) {}.padding(.top, Theme.Space.m)
            }
            .padding(.bottom, Theme.Space.l)
        }
        .onAppear { focused = true }
    }

    private var summaryParts: [(text: String, isAccent: Bool)] {
        let zone = TimeZone(identifier: zoneIdentifier) ?? .current
        let day = SheetFormat.day(Date(timeIntervalSince1970: Double(range.startUnixMilliseconds) / 1_000), zone: zone)
        return [
            (day + " · ", false),
            (Formatting.time(range.startUnixMilliseconds, zoneIdentifier: zoneIdentifier), true),
            (" – " + Formatting.time(range.endUnixMilliseconds, zoneIdentifier: zoneIdentifier), false)
        ]
    }

    private func save() {
        guard let chosen else { return }
        onSave(title, chosen)
    }
}
