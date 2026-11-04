import NEOBudgetCalendar
import SwiftUI

/// Makes an event (design-v2 polish/create-v11 and ledger/openend-v1). It opens small, over the keyboard: a title, the calendar, one gray line of when.
/// Pulled up, the same sheet shows the rest as rows. A time written in the title ("18시 저녁 약속") is offered as one "18:00 – 미정" button; pressing it
/// takes the time out of the title and sets the start. Saved without it, the event is all-day. A start with no end is saved as 종료 미정
/// (`NewEventInput.plan`): there is no switch and no end picker to ask for one, an empty end is the open end.
struct EventCreateSheet: View {
    let model: AppModel
    let close: () -> Void
    @State private var title = ""
    @State private var calendarID: CalendarID?
    @State private var day: Date
    @State private var startMinute: Int?
    @State private var endMinute: Int?
    @State private var location = ""
    @State private var notes = ""
    @State private var people: Set<PersonID> = []
    @State private var showsPeople = false
    @State private var failure: String?
    @State private var isSaving = false
    @State private var isOpen = false
    @FocusState private var titleFocused: Bool

    init(model: AppModel, close: @escaping () -> Void) {
        self.model = model
        self.close = close
        var parts = DateComponents()
        parts.year = model.selectedDay.year; parts.month = model.selectedDay.month; parts.day = model.selectedDay.day
        _day = State(initialValue: Calendar.current.date(from: parts) ?? Date())
    }

    private var writable: [CalendarDescriptor] { model.calendars.filter(\.isWritable) }
    private var suggestion: TitleTimeSuggestion? { startMinute == nil ? TitleTimeSuggestion.find(in: title) : nil }
    private var canSave: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty && (calendarID ?? writable.first?.id) != nil && !isSaving }

    var body: some View {
        PanelSheet(isOpen: $isOpen, close: close) {
            VStack(alignment: .leading, spacing: 0) {
                SheetTitleLine(canSave: canSave, save: save) {
                    SheetTitleField(text: $title, highlight: suggestion.flatMap { SheetFormat.timeRun(in: title, stripped: $0.strippedTitle) }, focus: $titleFocused, submit: { if canSave { save() } })
                }
                if writable.count > 1 { SheetCalendarChips(calendars: writable, selection: $calendarID).padding(.top, Theme.Space.m) }
                if isOpen {
                    ScrollView { rows }.scrollIndicators(.hidden).padding(.top, Theme.Space.s)
                } else {
                    summary.padding(.top, Theme.Space.m)
                }
                if let failure { Text(failure).font(Theme.Typo.caption).foregroundStyle(Theme.danger).padding(.top, Theme.Space.s) }
            }
            .padding(.bottom, isOpen ? 0 : Theme.Space.l)
        }
        .onAppear {
            titleFocused = true
            calendarID = calendarID ?? writable.first?.id
        }
        .onChange(of: isOpen) { _, now in if now { titleFocused = false } }
    }

    // MARK: Small

    private var summary: some View {
        SheetSummaryLine(parts: summaryParts) {
            if let suggestion { SuggestionPill(text: suggestion.label) { take(suggestion) } }
        }
    }

    private var summaryParts: [(text: String, isAccent: Bool)] {
        var parts = [(SheetFormat.day(day, zone: zone) + " · ", false)]
        guard let startMinute else { return parts + [("종일", false)] }
        parts.append((SheetFormat.clock(minute: startMinute), false))
        parts.append((endMinute.map { " – " + SheetFormat.clock(minute: $0) } ?? " –", false))
        return parts
    }

    // MARK: Open

    private var rows: some View {
        VStack(spacing: 0) {
            SheetRow("날짜") { SheetPickerValue(text: SheetFormat.day(day, zone: zone), date: $day, components: .date, zone: zone) }
            SheetRow("종일") { SheetToggle(isOn: allDay, label: "종일") }
            if let startMinute {
                SheetRow("시작") { SheetPickerValue(text: SheetFormat.clock(minute: startMinute), date: time($startMinute, fallback: 9 * 60), components: .hourAndMinute, zone: zone) }
                SheetRow("종료") {
                    if let endMinute {
                        HStack(spacing: Theme.Space.m) {
                            SheetPickerValue(text: SheetFormat.clock(minute: endMinute), date: time($endMinute, fallback: 10 * 60), components: .hourAndMinute, zone: zone)
                            Button { self.endMinute = nil } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textTertiary).frame(width: 28, height: 28).background(Theme.fill, in: Circle()) }
                                .buttonStyle(.plain).accessibilityLabel("종료 시각 지우기")
                        }
                    } else {
                        Button { self.endMinute = min(startMinute + 60, 23 * 60 + 59) } label: { SheetValue(text: "추가", isSet: false) }.buttonStyle(.plain)
                    }
                }
            }
            SheetRow("장소") { SheetTextValue(placeholder: "추가", text: $location) }
            SheetRow("함께하는 사람", showsDivider: !showsPeople) {
                Button { withAnimation(Theme.Motion.press) { showsPeople.toggle() } } label: { SheetValue(text: peopleText, isSet: !people.isEmpty) }.buttonStyle(.plain)
            }
            if showsPeople { peoplePicker.padding(.vertical, Theme.Space.m) }
            SheetRow("메모", showsDivider: false) { SheetTextValue(placeholder: "추가", text: $notes) }
        }
    }

    private var peoplePicker: some View {
        PeoplePicker(
            people: model.catalog.people, chosen: people, showsSelf: false,
            toggle: { id in if people.contains(id) { people.remove(id) } else { people.insert(id) } },
            add: { name in
                Task {
                    let person = Person(id: PersonID(rawValue: ActivityEditing.newID(prefix: "person")), displayName: name)
                    _ = await model.perform(.upsertPerson(person))
                    people.insert(person.id)
                }
            }
        )
    }

    private var peopleText: String {
        let names = model.catalog.people.filter { people.contains($0.id) }.map(\.name)
        return names.isEmpty ? "추가" : names.joined(separator: ", ")
    }

    // MARK: Time

    private var zone: TimeZone { TimeZone(identifier: model.dayZone.identifier) ?? .current }

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
        let place = ActivityEditing.cleanName(location), memo = ActivityEditing.cleanName(notes)
        Task {
            let message = await model.createEvent(input, location: place, notes: memo, people: Array(people))
            isSaving = false
            if let message { failure = message } else { close() }
        }
    }
}

extension SheetRow {
    init(_ label: String, showsDivider: Bool = true, @ViewBuilder value: @escaping () -> Value) {
        self.init(label: label, showsDivider: showsDivider, value: value)
    }
}
