import NEOBudgetCalendar
import SwiftUI

// The parts of the create sheets (design-v2/polish/create-v11 and ledger/openend-v1): a title line with its save button, calendar chips, a gray summary
// line, and the rows of the opened-up sheet. The event sheets and the transaction sheet are built from these.

/// The sheet's first line: what is being made, typed straight in, and the one small blue 저장 button.
struct SheetTitleLine<Field: View>: View {
    let canSave: Bool
    let save: () -> Void
    @ViewBuilder let field: () -> Field

    var body: some View {
        HStack(spacing: Theme.Space.m - 2) {
            field().frame(maxWidth: .infinity, alignment: .leading)
            Button("저장", action: save)
                .buttonStyle(SmallSaveButtonStyle())
                .disabled(!canSave)
        }
        .frame(minHeight: Theme.smallButtonHeight)
    }
}

/// 36 high, 12 corners, 15/600 white on blue; grays out when it cannot be pressed.
struct SmallSaveButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typo.smallButton)
            .foregroundStyle(.white)
            .padding(.horizontal, Theme.Space.l)
            .frame(height: Theme.smallButtonHeight)
            .background(isEnabled ? Theme.accent : Theme.disabled, in: RoundedRectangle(cornerRadius: Theme.Radius.smallButton, style: .continuous))
            .opacity(configuration.isPressed ? Theme.Motion.pressedButtonOpacity : 1)
            .animation(Theme.Motion.press, value: configuration.isPressed)
    }
}

/// The title being typed. `highlight` is the part that reads as a time ("18시"); it is drawn blue under a transparent field, so the cursor and
/// selection are the system's own.
struct SheetTitleField: View {
    @Binding var text: String
    var placeholder = "제목"
    var highlight: Range<String.Index>?
    var focus: FocusState<Bool>.Binding
    var submit: () -> Void = {}

    var body: some View {
        ZStack(alignment: .leading) {
            if text.isEmpty {
                Text(placeholder).font(Theme.Typo.sheetTitle).foregroundStyle(Theme.disabled).accessibilityHidden(true)
            } else {
                Text(shown).font(Theme.Typo.sheetTitle).lineLimit(1).accessibilityHidden(true)
            }
            TextField(placeholder, text: $text)
                .font(Theme.Typo.sheetTitle)
                .foregroundStyle(.clear)
                .tint(Theme.accent)
                .focused(focus)
                .submitLabel(.done)
                .onSubmit(submit)
        }
    }

    private var shown: AttributedString {
        var result = AttributedString(text)
        result.foregroundColor = Theme.textPrimary
        if let highlight, let range = Range(highlight, in: result) { result[range].foregroundColor = Theme.accent }
        return result
    }
}

/// The calendars an event can go in, one chosen: 32 high, filled, the calendar's color as a dot.
struct SheetCalendarChips: View {
    let calendars: [CalendarDescriptor]
    @Binding var selection: CalendarID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.s) {
                ForEach(calendars, id: \.id) { calendar in
                    let chosen = (selection ?? calendars.first?.id) == calendar.id
                    Button { selection = calendar.id } label: {
                        HStack(spacing: 5) {
                            Circle().fill(Color(hex: calendar.colorHex) ?? Theme.accent).frame(width: 8, height: 8)
                            Text(calendar.title).font(Theme.Typo.chip)
                        }
                        .foregroundStyle(chosen ? Theme.accentStrong : Theme.textSecondary)
                        .padding(.horizontal, 14).frame(height: Theme.chipHeight)
                        .background(chosen ? Theme.accentSoft : Theme.fill, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                }
            }
        }
    }
}

/// The gray line under the chips ("11월 3일 화 · 종일"). The small blue pill beside it is the one thing the sheet suggests.
struct SheetSummaryLine<Suggestion: View>: View {
    let parts: [(text: String, isAccent: Bool)]
    @ViewBuilder let suggestion: () -> Suggestion

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            parts.reduce(Text("")) { $0 + Text($1.text).foregroundStyle($1.isAccent ? Theme.accent : Theme.textTertiary) }
                .font(Theme.Typo.label)
            suggestion()
        }
        .frame(minHeight: 28)
    }
}

/// 28 high, 8 corners, 13/500 blue on pale blue: the pill that offers a time found in the title.
struct SuggestionPill: View {
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text).font(Theme.Typo.chip).foregroundStyle(Theme.accentStrong)
                .padding(.horizontal, 10).frame(height: 28)
                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// One row of the opened-up sheet: its name in gray on the left, its value on the right. 56 high, a hairline below.
struct SheetRow<Value: View>: View {
    let label: String
    var showsDivider = true
    @ViewBuilder let value: () -> Value

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Text(label).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textTertiary)
            Spacer(minLength: Theme.Space.s)
            value()
        }
        .frame(minHeight: 56)
        .overlay(alignment: .bottom) { if showsDivider { Rectangle().fill(Theme.divider).frame(height: 1) } }
    }
}

/// A value on a row: 16/500 dark when it is set, light gray when it is the empty answer ("추가", "안 함").
struct SheetValue: View {
    let text: String
    var isSet = true

    var body: some View {
        Text(text).font(Theme.Typo.rowTitle).foregroundStyle(isSet ? Theme.textPrimary : Theme.disabled).multilineTextAlignment(.trailing)
    }
}

/// A row value that reads as plain text but opens the system picker when tapped.
struct SheetPickerValue: View {
    let text: String
    @Binding var date: Date
    var components: DatePickerComponents
    var zone: TimeZone = .current

    var body: some View {
        SheetValue(text: text)
            .overlay {
                DatePicker("", selection: $date, displayedComponents: components)
                    .labelsHidden()
                    .environment(\.timeZone, zone)
                    .colorMultiply(.clear)
                    .blendMode(.destinationOver)
                    .accessibilityLabel(text)
            }
    }
}

/// A text field that sits in a row, right-aligned, empty until typed in.
struct SheetTextValue: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundColor(Theme.disabled))
            .font(Theme.Typo.rowTitle)
            .foregroundStyle(Theme.textPrimary)
            .multilineTextAlignment(.trailing)
            .submitLabel(.done)
    }
}

enum SheetFormat {
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "M월 d일 E"
        return formatter
    }()

    /// "11월 3일 화".
    static func day(_ date: Date, zone: TimeZone = .current) -> String {
        dayFormatter.timeZone = zone
        return dayFormatter.string(from: date)
    }

    /// "18:00".
    static func clock(minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }

    /// "10원" → digits only as a number with thousands separators, "" for nothing typed.
    static func grouped(_ digits: String) -> String {
        guard let value = Int64(digits.filter(\.isNumber)) else { return "" }
        return value.formatted(.number.grouping(.automatic).locale(Locale(identifier: "ko_KR")))
    }

    /// Where a time such as "18시" sits in the title, found by what is left once the suggestion has taken it out.
    static func timeRun(in title: String, stripped: String) -> Range<String.Index>? {
        let t = Array(title), s = Array(stripped)
        var head = 0
        while head < min(s.count, t.count), t[head] == s[head] { head += 1 }
        var tail = 0
        while tail < min(s.count, t.count) - head, t[t.count - 1 - tail] == s[s.count - 1 - tail] { tail += 1 }
        var lo = head, hi = t.count - tail
        while hi > lo, t[hi - 1].isWhitespace { hi -= 1 }
        while lo < hi, t[lo].isWhitespace { lo += 1 }
        guard lo < hi else { return nil }
        let start = title.index(title.startIndex, offsetBy: lo), end = title.index(title.startIndex, offsetBy: hi)
        return start..<end
    }
}

/// 48×28, off #C6C6CB, on blue (the switch every row uses).
struct SheetToggle: View {
    @Binding var isOn: Bool
    let label: String

    var body: some View {
        Button { withAnimation(Theme.Motion.press) { isOn.toggle() } } label: {
            Capsule().fill(isOn ? Theme.accent : Theme.disabled).frame(width: 48, height: 28)
                .overlay(alignment: isOn ? .trailing : .leading) { Circle().fill(.white).frame(width: 24, height: 24).padding(2) }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "켜짐" : "꺼짐")
        .accessibilityAddTraits(.isButton)
    }
}

/// Two or three options in one track: 32 high, 10 corners outside and 8 inside; on a white sheet the track is #F4F5F7 and the chosen one is pale blue.
struct SheetSegments: View {
    let options: [String]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let chosen = selection == index
                Button { withAnimation(Theme.Motion.press) { selection = index } } label: {
                    Text(options[index]).font(Theme.Typo.chip.weight(chosen ? .semibold : .medium))
                        .foregroundStyle(chosen ? Theme.accentStrong : Theme.textSecondary)
                        .frame(maxWidth: .infinity).frame(height: Theme.segmentHeight - 4)
                        .background(chosen ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(2)
        .frame(height: Theme.segmentHeight + 4)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.Radius.segment, style: .continuous))
    }
}

extension SheetFormat {
    /// "18:00" of a moment in a zone.
    static func clock(of date: Date, zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return clock(minute: (parts.hour ?? 0) * 60 + (parts.minute ?? 0))
    }
}

/// The create sheet as the design draws it: a white panel resting on the keyboard, the screen dimmed above it. It is drawn over the screen
/// (an overlay, not a system sheet: a short system sheet jumps to full height when the keyboard comes up and hides the screen behind it).
/// Pulled up (`isOpen`) the panel grows to nearly the whole screen; pulled down or tapped outside it closes.
struct PanelSheet<Content: View>: View {
    @Binding var isOpen: Bool
    var canOpen = true
    let close: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var shown = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(rgb: 0x191F28).opacity(0.42).ignoresSafeArea().opacity(shown ? 1 : 0)
                .contentShape(Rectangle()).onTapGesture(perform: close)
            VStack(spacing: 0) {
                Capsule().fill(Theme.disabled).frame(width: 36, height: 4).padding(.top, Theme.Space.s).padding(.bottom, Theme.Space.s + 2)
                content()
                if isOpen { Spacer(minLength: 0) }
            }
            .padding(.horizontal, Theme.Space.xl)
            .frame(maxWidth: .infinity, maxHeight: isOpen ? .infinity : nil, alignment: .top)
            .background(
                UnevenRoundedRectangle(topLeadingRadius: Theme.Radius.sheet, topTrailingRadius: Theme.Radius.sheet, style: .continuous)
                    .fill(Theme.surface).ignoresSafeArea(.all, edges: .bottom)
            )
            .contentShape(Rectangle())
            .simultaneousGesture(DragGesture(minimumDistance: 12).onEnded { drag in
                if drag.translation.height < -40, canOpen { withAnimation(Theme.Motion.sheet) { isOpen = true } }
                else if drag.translation.height > 40 { if isOpen { withAnimation(Theme.Motion.sheet) { isOpen = false } } else { close() } }
            })
            .padding(.top, isOpen ? 70 : 0)
            .offset(y: shown ? 0 : 700)
        }
        .tint(Theme.accent)
        .onAppear { withAnimation(Theme.Motion.sheet) { shown = true } }
    }
}
