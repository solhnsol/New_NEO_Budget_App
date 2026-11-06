import SwiftUI

/// Which end of the chosen event a precision bubble is for.
enum PrecisionEdge: Equatable, Sendable {
    case start, end

    /// The bubble for a handle (`nil` for the event's body, which has none).
    init?(_ hit: EditHit) {
        switch hit {
        case .resizeStart: self = .start
        case .resizeEnd: self = .end
        case .body: return nil
        }
    }
}

/// What a precision bubble shows. The bubble is controlled: it shows this and reports what was pressed (`PrecisionBubbleAction`). It never works out a new
/// time, touches a draft or writes to the calendar; whoever owns the edit does that and hands it the result.
struct PrecisionBubbleInput: Equatable {
    var edge: PrecisionEdge
    /// The edge's time as it is now (the date is shown too, so an end at midnight reads as the next day).
    var instant: Date
    var timeZone: TimeZone
    /// Whether a 15-minute step back / forward may be taken now (the other edge, the session's limits, a save in progress).
    var canDecrement: Bool = true
    var canIncrement: Bool = true
    /// The times the wheel offers (`PrecisionWheelChoices`), in order; `instant` is one of them. Empty: the wheel shows `instant` alone.
    var choices: [Date] = []

    /// The wheel's rows: `choices`, or `instant` alone.
    var wheelChoices: [Date] { choices.isEmpty ? [instant] : choices }

    var isInteractive: Bool { canDecrement || canIncrement }

    /// What a control does now: its action, or `nil` while it is off.
    func action(for control: PrecisionBubbleControl) -> PrecisionBubbleAction? {
        switch control {
        case .decrement: canDecrement ? .decrement15 : nil
        case .increment: canIncrement ? .increment15 : nil
        case .dismiss: .dismiss
        }
    }
}

/// What a precision bubble reports.
enum PrecisionBubbleAction: Equatable, Sendable {
    /// One 15-minute step (VoiceOver's adjustment of the header).
    case decrement15
    case increment15
    /// The wheel turned to this time (one of the input's `choices`).
    case set(Date)
    case dismiss
}

/// The bubble's controls, buttons and assistive actions alike.
enum PrecisionBubbleControl: Equatable, Sendable {
    case decrement, increment, dismiss

    /// VoiceOver's adjustable increment (swipe up) makes the time later, decrement (swipe down) earlier.
    init?(_ direction: AccessibilityAdjustmentDirection) {
        switch direction {
        case .increment: self = .increment
        case .decrement: self = .decrement
        @unknown default: return nil
        }
    }
}

/// The words of a precision bubble, for the screen and for VoiceOver.
struct PrecisionBubbleText: Equatable {
    /// "시작" / "종료".
    let edge: String
    /// "10월 13일 (화)".
    let date: String
    /// "오후 2:15".
    let time: String
    /// "시작 시각" / "종료 시각".
    let accessibilityLabel: String
    /// "10월 13일 화요일 오후 2:15".
    let accessibilityValue: String
    let accessibilityHint: String
    let dismissLabel = "닫기"

    @MainActor init(_ input: PrecisionBubbleInput) {
        edge = input.edge == .start ? "시작" : "종료"
        date = Self.string(input.instant, input.timeZone, "M월 d일 (E)")
        time = Self.string(input.instant, input.timeZone, "a h:mm")
        accessibilityLabel = "\(edge) 시각"
        accessibilityValue = Self.string(input.instant, input.timeZone, "M월 d일 EEEE a h:mm")
        switch (input.canDecrement, input.canIncrement) {
        case (true, true): accessibilityHint = "위로 쓸면 15분 늦게, 아래로 쓸면 15분 일찍"
        case (false, true): accessibilityHint = "위로 쓸면 15분 늦게. 더 일찍은 안 돼요"
        case (true, false): accessibilityHint = "아래로 쓸면 15분 일찍. 더 늦게는 안 돼요"
        case (false, false): accessibilityHint = "지금은 바꿀 수 없어요"
        }
    }

    /// A row of the wheel: "오후 2:15"; an end at midnight is "자정" (the header's date says which day it ends on).
    @MainActor static func wheelLabel(_ instant: Date, edge: PrecisionEdge, timeZone: TimeZone) -> String {
        let time = string(instant, timeZone, "a h:mm")
        return edge == .end && string(instant, timeZone, "HH:mm") == "00:00" ? "자정" : time
    }

    @MainActor private static var formatters: [String: DateFormatter] = [:]

    @MainActor private static func string(_ date: Date, _ zone: TimeZone, _ format: String) -> String {
        let key = zone.identifier + "|" + format
        let formatter: DateFormatter
        if let known = formatters[key] {
            formatter = known
        } else {
            formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ko_KR")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = zone
            formatter.dateFormat = format
            formatters[key] = formatter
        }
        return formatter.string(from: date)
    }
}

/// The precision bubble's body: which edge and its date, a wheel of times in 15-minute steps (the middle row is the edge's time), and close. Placing it next to
/// the handle is `PrecisionBubbleOverlay`'s job; this draws the body at the width it is given and reports what was chosen.
///
/// - The wheel reports each row as it passes the middle, so the card follows it while it turns; a tap on a row turns to it. While a handle is dragged the
///   wheel follows the handle and takes no touches.
/// - Dynamic Type: text styles throughout; the rows grow with the text and the header wraps (`PrecisionBubbleMetrics`).
/// - VoiceOver: the time is one adjustable element (swipe up +15, down −15, only where allowed); the wheel is hidden from it; close is a button; the
///   escape gesture closes.
struct PrecisionEditBubble: View {
    let input: PrecisionBubbleInput
    /// Which way the handle is when it is off screen (`pinnedTop` / `pinnedBottom`); `nil` otherwise.
    var offscreen: PrecisionBubbleLayout.Side? = nil
    let onAction: (PrecisionBubbleAction) -> Void

    var body: some View {
        let text = PrecisionBubbleText(input)
        let choices = input.wheelChoices
        VStack(alignment: .leading, spacing: 4) {
            header(text)
            PrecisionTimeWheel(
                labels: choices.map { PrecisionBubbleText.wheelLabel($0, edge: input.edge, timeZone: input.timeZone) },
                selected: PrecisionWheelChoices.index(of: input.instant, in: choices) ?? 0,
                isEnabled: input.isInteractive,
                onSelect: { row in
                    guard choices.indices.contains(row), choices[row] != input.instant else { return }
                    onAction(.set(choices[row]))
                }
            )
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(text.edge) 시각 조정")
        .accessibilityAction(.escape) { send(.dismiss) }
    }

    private func header(_ text: PrecisionBubbleText) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let offscreen {
                Image(systemName: offscreen == .pinnedTop ? "chevron.up" : "chevron.down")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
            Text("\(text.edge) · \(text.date)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                // The one element VoiceOver adjusts: the edge, the whole date and the time.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(text.accessibilityLabel)
                .accessibilityValue(text.accessibilityValue)
                .accessibilityHint(text.accessibilityHint)
                .accessibilityAddTraits(input.isInteractive ? [] : .isStaticText)
                .accessibilityAdjustableAction { direction in
                    guard let control = PrecisionBubbleControl(direction) else { return }
                    send(control)
                }
                .accessibilitySortPriority(2)
            Button { send(.dismiss) } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: PrecisionBubbleMetrics.minimumTarget, height: PrecisionBubbleMetrics.minimumTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The 44pt target reaches into the padding; the glyph stays in the corner.
            .padding(.vertical, -14)
            .padding(.trailing, -12)
            .accessibilityLabel(text.dismissLabel)
            .accessibilitySortPriority(0)
        }
    }

    private func send(_ control: PrecisionBubbleControl) {
        guard let action = input.action(for: control) else { return }
        onAction(action)
    }
}

/// Sizes that depend on Dynamic Type, kept in one place so the overlay and the tests agree with the drawing.
enum PrecisionBubbleMetrics {
    static let minimumTarget: CGFloat = 44

    /// The bubble's width before the area limits it: wide enough for the header ("종료 · 10월 13일 (화)" and close) and "오후 12:45" on the wheel.
    static func preferredWidth(_ size: DynamicTypeSize) -> CGFloat {
        switch size {
        case ...DynamicTypeSize.large: 196
        case .xLarge: 208
        case .xxLarge: 220
        case .xxxLarge: 236
        case .accessibility1: 260
        case .accessibility2: 284
        default: 308
        }
    }

    /// The bubble's width in an area this wide (it keeps inside it).
    static func width(_ size: DynamicTypeSize, available: CGFloat) -> CGFloat { max(0, min(preferredWidth(size), available)) }

    /// The largest size the bubble draws at. Beyond it the bubble would cover most of a phone screen and leave the handle little room to move.
    static let largestSize = DynamicTypeSize.accessibility3
}
