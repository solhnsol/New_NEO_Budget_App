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
    case decrement15
    case increment15
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
    let decrementTitle = "−15분"
    let incrementTitle = "+15분"
    /// "시작 시각" / "종료 시각".
    let accessibilityLabel: String
    /// "10월 13일 화요일 오후 2:15".
    let accessibilityValue: String
    let accessibilityHint: String
    let decrementLabel = "15분 앞당기기"
    let incrementLabel = "15분 늦추기"
    let dismissLabel = "닫기"

    @MainActor init(_ input: PrecisionBubbleInput) {
        edge = input.edge == .start ? "시작" : "종료"
        date = Self.string(input.instant, input.timeZone, "M월 d일 (E)")
        time = Self.string(input.instant, input.timeZone, "a h:mm")
        accessibilityLabel = "\(edge) 시각"
        accessibilityValue = Self.string(input.instant, input.timeZone, "M월 d일 EEEE a h:mm")
        switch (input.canDecrement, input.canIncrement) {
        case (true, true): accessibilityHint = "위로 쓸면 15분 늦게, 아래로 쓸면 15분 일찍"
        case (false, true): accessibilityHint = "위로 쓸면 15분 늦게. 더 일찍은 안 됩니다"
        case (true, false): accessibilityHint = "아래로 쓸면 15분 일찍. 더 늦게는 안 됩니다"
        case (false, false): accessibilityHint = "지금은 바꿀 수 없습니다"
        }
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

/// The precision bubble's body: which edge, its date and time, −15 / +15 and close. Placing it next to the handle is `PrecisionBubbleOverlay`'s job; this
/// draws the body at the width it is given and reports what was pressed.
///
/// - Dynamic Type: text styles throughout; at accessibility sizes the two steps stack and the header wraps (`PrecisionBubbleMetrics`).
/// - VoiceOver: the time is one adjustable element (swipe up +15, down −15, only where allowed); the steps and close are buttons; the escape gesture closes.
///   A step taken with a button announces the new time when it arrives (an adjustable element speaks its own new value).
/// - Holding a step button repeats it (`buttonRepeatBehavior`); each repeat is one action.
struct PrecisionEditBubble: View {
    let input: PrecisionBubbleInput
    /// Which way the handle is when it is off screen (`pinnedTop` / `pinnedBottom`); `nil` otherwise.
    var offscreen: PrecisionBubbleLayout.Side? = nil
    let onAction: (PrecisionBubbleAction) -> Void

    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var announceNext = false

    var body: some View {
        let text = PrecisionBubbleText(input)
        let stacked = PrecisionBubbleMetrics.stacksSteps(typeSize)
        VStack(alignment: .leading, spacing: 8) {
            header(text)
            Text(text.time)
                .font(.title2.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityHidden(true)
            let steps = Group {
                stepButton(.decrement, title: text.decrementTitle, label: text.decrementLabel)
                stepButton(.increment, title: text.incrementTitle, label: text.incrementLabel)
            }
            if stacked {
                VStack(spacing: 6) { steps }
            } else {
                HStack(spacing: 8) { steps }
            }
        }
        .padding(12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(text.edge) 시각 조정")
        .accessibilityAction(.escape) { send(.dismiss) }
        .onChange(of: input.instant) {
            guard announceNext else { return }
            announceNext = false
            AccessibilityNotification.Announcement("\(text.edge) \(PrecisionBubbleText(input).time)").post()
        }
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
                    send(control, announce: false)
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

    private func stepButton(_ control: PrecisionBubbleControl, title: String, label: String) -> some View {
        Button { send(control) } label: {
            Text(title)
                .font(.body.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: PrecisionBubbleMetrics.minimumTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(PrecisionStepButtonStyle())
        .buttonRepeatBehavior(.enabled)
        .disabled(input.action(for: control) == nil)
        .accessibilityLabel(label)
        .accessibilitySortPriority(1)
    }

    private func send(_ control: PrecisionBubbleControl, announce: Bool = true) {
        guard let action = input.action(for: control) else { return }
        if action != .dismiss { announceNext = announce }
        onAction(action)
    }
}

/// A step button: a tinted 44pt-high plate (the system bordered style pads it past that), dimmed while off.
private struct PrecisionStepButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isEnabled ? AnyShapeStyle(.tint.opacity(configuration.isPressed ? 0.24 : 0.12)) : AnyShapeStyle(.quaternary.opacity(0.5)))
            )
    }
}

/// Sizes that depend on Dynamic Type, kept in one place so the overlay and the tests agree with the drawing.
enum PrecisionBubbleMetrics {
    static let minimumTarget: CGFloat = 44

    /// At accessibility sizes the two steps stack (side by side they would not fit "+15분" at a readable size).
    static func stacksSteps(_ size: DynamicTypeSize) -> Bool { size.isAccessibilitySize }

    /// The bubble's width before the area limits it: wide enough for "오후 12:45" in title2 and two step buttons.
    static func preferredWidth(_ size: DynamicTypeSize) -> CGFloat {
        switch size {
        case ...DynamicTypeSize.large: 232
        case .xLarge: 248
        case .xxLarge: 264
        case .xxxLarge: 280
        case .accessibility1: 300
        case .accessibility2: 320
        default: 340
        }
    }

    /// The bubble's width in an area this wide (it keeps inside it).
    static func width(_ size: DynamicTypeSize, available: CGFloat) -> CGFloat { max(0, min(preferredWidth(size), available)) }

    /// The largest size the bubble draws at. Beyond it the bubble would cover most of a phone screen and leave the handle little room to move.
    static let largestSize = DynamicTypeSize.accessibility3
}
