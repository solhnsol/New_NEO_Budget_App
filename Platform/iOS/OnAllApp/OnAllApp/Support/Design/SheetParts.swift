import NEOBudgetCalendar
import SwiftUI

// The pieces the detail sheets share (event, transaction, settlement; design-v2 FULL-2/3/4, DETAIL-1/2/4, polish/CHANGES.md). Plain stacks on the
// white sheet, not a List: 20 side margin, rows 52 tall with a hairline between, text in the default color and only an amount in color.

/// A sheet's scrolling body with its one main button pinned under it.
struct SheetScaffold<Content: View, Button: View>: View {
    @ViewBuilder var content: () -> Content
    @ViewBuilder var button: () -> Button

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(.horizontal, Theme.Space.xl)
                .padding(.top, Theme.Space.xxl)
                .padding(.bottom, Theme.Space.l)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            button().padding(.horizontal, Theme.Space.xl).padding(.vertical, Theme.Space.s).background(Theme.surface)
        }
        .background(Theme.surface)
        .tint(Theme.accent)
    }
}

/// `이 일정의 지출`, `상세`: a small gray label over a group of rows.
struct SheetSectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(Theme.Typo.label).foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Theme.Space.xl).padding(.bottom, Theme.Space.xs)
    }
}

/// `결제 시각   11월 3일 11:40`: a gray label and its value, 52 tall, a hairline under it. `value` nil shows the placeholder in the lightest gray.
struct SheetRow: View {
    let label: String
    var value: String?
    /// Shown in the lightest gray while `value` is nil.
    var placeholder: String? = "추가하기"
    var valueColor: Color = Theme.textPrimary
    var valueWeight: Font.Weight = .regular
    var showsChevron = false
    var showsDivider = true
    var action: (() -> Void)?

    var body: some View {
        let row = HStack(spacing: Theme.Space.s) {
            Text(label).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textTertiary)
            Spacer(minLength: Theme.Space.m)
            if let shown = value ?? placeholder {
                Text(shown).font(.onAll(size: 16, weight: valueWeight).monospacedDigit())
                    .foregroundStyle(value == nil ? Theme.disabled : valueColor).multilineTextAlignment(.trailing).lineLimit(2)
            }
            if showsChevron { Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textTertiary) }
        }
        .frame(minHeight: Theme.rowHeight)
        .overlay(alignment: .bottom) { if showsDivider { Theme.divider.frame(height: 1) } }
        .contentShape(Rectangle())
        if let action {
            Button(action: action) { row }.buttonStyle(.onAllRow)
        } else {
            row
        }
    }
}

/// A line icon on a pale tint, at the start of a row: the category's (`CategoryIcon.tile`).
struct CategoryTile: View {
    let category: CanonicalCategoryID?
    var size: CGFloat = 38

    var body: some View {
        let tile = CategoryIcon.tile(for: category)
        LineIcon(name: tile.icon, size: size * 0.5).foregroundStyle(Theme.textSecondary)
            .frame(width: size, height: size)
            .background(tile.tint, in: RoundedRectangle(cornerRadius: size * 0.32, style: .continuous))
    }
}

/// `일정 이름` over a second gray line, with a calendar-colored bar at its side (the event card's rail).
struct SheetTitleBlock: View {
    let title: String
    let lines: [String]
    var barColor: Color?

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            if let barColor { RoundedRectangle(cornerRadius: 2).fill(barColor).frame(width: 4) }
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(title).font(Theme.Typo.sheetTitle).foregroundStyle(Theme.textPrimary)
                ForEach(lines, id: \.self) { Text($0).font(Theme.Typo.label).foregroundStyle(Theme.textTertiary) }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension Formatting {
    /// `14:30`, 24-hour like the timeline and the mockups (`Formatting.time` writes `오후 2:30`).
    static func clock24(_ unixMilliseconds: Int64, zoneIdentifier: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zoneIdentifier) ?? .current
        let parts = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: Double(unixMilliseconds) / 1_000))
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// `12:15 – 13:30`.
    static func range24(_ start: Int64, _ end: Int64, zoneIdentifier: String) -> String {
        clock24(start, zoneIdentifier: zoneIdentifier) + " – " + clock24(end, zoneIdentifier: zoneIdentifier)
    }

    /// Money spent as the sheets write it: `−9,500` (a true minus sign, no unit).
    static func spent(_ minorUnits: Int64) -> String { "−" + grouped(minorUnits) }
}


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
struct FormRow<Value: View>: View {
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
/// `small` is what shows at rest; `more` is under it and is uncovered as the panel is pulled up. Pulled down from rest, or a tap outside, it goes away.
///
/// The panel is UIKit-driven so it moves like a system sheet: its content is laid out once at full height inside a hosting controller, a pan
/// recognizer moves the container's transform directly (no SwiftUI pass per touch), and on release a spring takes over with the finger's own speed.
struct PanelSheet<Small: View, More: View>: View {
    @Binding var isOpen: Bool
    var canOpen = true
    let close: () -> Void
    /// Asked when the user closes it (a tap outside, pulled down); `false` keeps it open (the caller asks what to do about unsaved changes).
    var shouldClose: () -> Bool = { true }
    /// Already up when it appears (it takes the place of a panel that was showing the same thing while it loaded).
    var appearsShown = false
    let small: Small
    let more: More

    init(isOpen: Binding<Bool>, canOpen: Bool = true, close: @escaping () -> Void, shouldClose: @escaping () -> Bool = { true }, appearsShown: Bool = false, @ViewBuilder content: () -> Small, @ViewBuilder more: () -> More) {
        _isOpen = isOpen
        self.canOpen = canOpen
        self.close = close
        self.shouldClose = shouldClose
        self.appearsShown = appearsShown
        small = content()
        self.more = more()
    }

    var body: some View {
        PanelHost(sheet: self).ignoresSafeArea()
    }
}

private struct PanelHost<Small: View, More: View>: UIViewControllerRepresentable {
    let sheet: PanelSheet<Small, More>

    func makeUIViewController(context: Context) -> PanelController<Small, More> { PanelController(sheet: sheet) }
    func updateUIViewController(_ controller: PanelController<Small, More>, context: Context) { controller.update(sheet) }
}

/// Whether `more` is drawn: at rest it hangs below the panel into the home-indicator strip, where it must stay unseen.
@MainActor private final class PanelFlags: ObservableObject {
    @Published var moreVisible = false
}

/// The panel's content at its full open height. It reports what it needs (`small`, and how far `more` opens) and is moved from outside.
private struct PanelRoot<Small: View, More: View>: View {
    let canOpen: Bool
    let small: Small
    let more: More
    let dismiss: PanelDismiss
    @ObservedObject var flags: PanelFlags
    let onMetrics: (CGFloat, CGFloat) -> Void
    @State private var smallHeight: CGFloat = 0
    @State private var moreHeight: CGFloat = 0

    /// What `more` opens by: its own height, at most 55% of the screen (the design: `min(scrollHeight, innerHeight * .55)`).
    private func extent(_ more: CGFloat) -> CGFloat { canOpen && more > 0 ? min(more, UIScreen.main.bounds.height * 0.55) : 0 }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                Capsule().fill(Theme.disabled).frame(width: 36, height: 4).padding(.top, Theme.Space.s).padding(.bottom, Theme.Space.s + 2)
                small
            }
            .padding(.bottom, Theme.Space.l)
            .background(GeometryReader { proxy in Color.clear.preference(key: PanelSmallHeightKey.self, value: proxy.size.height) })
            if canOpen {
                ScrollView { more.background(GeometryReader { proxy in Color.clear.preference(key: PanelMoreHeightKey.self, value: proxy.size.height) }) }
                    .scrollIndicators(.hidden).frame(height: extent(moreHeight))
                    .opacity(flags.moreVisible ? 1 : 0)
            }
        }
        .padding(.horizontal, Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(UnevenRoundedRectangle(topLeadingRadius: Theme.Radius.sheet, topTrailingRadius: Theme.Radius.sheet, style: .continuous).fill(Theme.surface))
        .onPreferenceChange(PanelSmallHeightKey.self) { value in smallHeight = value; onMetrics(value, extent(moreHeight)) }
        .onPreferenceChange(PanelMoreHeightKey.self) { value in moreHeight = value; onMetrics(smallHeight, extent(value)) }
        .tint(Theme.accent)
        .environment(\.panelDismiss, dismiss)
    }
}

@MainActor private final class PanelController<Small: View, More: View>: UIViewController, UIGestureRecognizerDelegate {
    private var sheet: PanelSheet<Small, More>
    private let flags = PanelFlags()
    private let dim = UIView()
    private let panel = UIView()
    private let skirt = UIView()
    private var host: UIHostingController<PanelRoot<Small, More>>?
    private var heightConstraint: NSLayoutConstraint?
    private var smallHeight: CGFloat = 0
    /// How far the panel's lower part hangs below the screen at rest (what `more` needs).
    private var extent: CGFloat = 0
    /// Where the panel was last told to rest: 0 small, 1 open.
    private var resting: CGFloat = 0
    private var presented = false
    private var closing = false
    private var animator: UIViewPropertyAnimator?
    private var panStartY: CGFloat = 0

    init(sheet: PanelSheet<Small, More>) {
        self.sheet = sheet
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        dim.backgroundColor = UIColor(red: 25 / 255, green: 31 / 255, blue: 40 / 255, alpha: 0.42)
        dim.alpha = 0
        dim.frame = view.bounds
        dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dim.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tappedOutside)))
        view.addSubview(dim)

        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.alpha = 0
        view.addSubview(panel)
        let height = panel.heightAnchor.constraint(equalToConstant: 1)
        heightConstraint = height
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            height,
        ])

        // The white that fills the strip under the panel (home indicator) and whatever hangs below while it is pushed down.
        skirt.translatesAutoresizingMaskIntoConstraints = false
        skirt.backgroundColor = UIColor(Theme.surface)
        panel.addSubview(skirt)
        NSLayoutConstraint.activate([
            skirt.topAnchor.constraint(equalTo: panel.bottomAnchor),
            skirt.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            skirt.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            skirt.heightAnchor.constraint(equalToConstant: 800),
        ])

        let host = UIHostingController(rootView: makeRoot())
        self.host = host
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        // The panel slides over the home-indicator strip; without this the content would inset itself there and leave a gap at its foot while it moves.
        host.safeAreaRegions = []
        panel.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: panel.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
        ])
        host.didMove(toParent: self)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.delegate = self
        panel.addGestureRecognizer(pan)
        panel.transform = CGAffineTransform(translationX: 0, y: view.bounds.height)
    }

    private func makeRoot() -> PanelRoot<Small, More> {
        PanelRoot(canOpen: sheet.canOpen, small: sheet.small, more: sheet.more, dismiss: PanelDismiss(run: { [weak self] in self?.dismiss() }), flags: flags,
                  onMetrics: { [weak self] small, extent in self?.metrics(small: small, extent: extent) })
    }

    func update(_ new: PanelSheet<Small, More>) {
        sheet = new
        host?.rootView = makeRoot()
        guard presented, !closing else { return }
        // The owner opened or closed it (not by a finger): follow.
        if (resting > 0.5) != new.isOpen, new.canOpen { settle(to: new.isOpen ? 1 : 0, velocity: 0) }
    }

    // MARK: Placement

    private var restY: CGFloat { extent * (1 - resting) }
    private var offscreenY: CGFloat { (heightConstraint?.constant ?? 0) + view.safeAreaInsets.bottom + 8 }

    private func metrics(small: CGFloat, extent newExtent: CGFloat) {
        guard small > 0 else { return }
        smallHeight = small
        extent = newExtent
        heightConstraint?.constant = small + newExtent
        view.layoutIfNeeded()
        if !presented {
            presented = true
            if sheet.appearsShown {
                panel.transform = CGAffineTransform(translationX: 0, y: restY)
                panel.alpha = 1
                dim.alpha = 1
            } else {
                panel.transform = CGAffineTransform(translationX: 0, y: offscreenY)
                panel.alpha = 1
                animate(to: restY, velocity: 0, dim: 1)
            }
        } else if !closing, animator?.isRunning != true {
            panel.transform = CGAffineTransform(translationX: 0, y: restY)
        }
    }

    /// Moves to `y` by a spring that starts at the finger's speed (points per second, down positive), and the dim with it.
    private func animate(to y: CGFloat, velocity: CGFloat, dim target: CGFloat, completion: (() -> Void)? = nil) {
        animator?.stopAnimation(true)
        let distance = y - panel.transform.ty
        let relative = abs(distance) > 1 ? max(-20, min(20, velocity / distance)) : 0
        let timing = UISpringTimingParameters(dampingRatio: 0.86, initialVelocity: CGVector(dx: relative, dy: relative))
        let animator = UIViewPropertyAnimator(duration: 0.42, timingParameters: timing)
        animator.addAnimations { [panel, dim] in
            panel.transform = CGAffineTransform(translationX: 0, y: y)
            dim.alpha = target
        }
        animator.addCompletion { _ in completion?() }
        self.animator = animator
        animator.startAnimation()
    }

    private func settle(to target: CGFloat, velocity: CGFloat) {
        resting = sheet.canOpen ? target : 0
        if resting > 0 { flags.moreVisible = true }
        if (resting == 1) != sheet.isOpen, sheet.canOpen { sheet.isOpen = resting == 1 }
        let goal = resting
        animate(to: restY, velocity: velocity, dim: 1) { [weak self] in
            guard let self, self.resting == goal, goal == 0 else { return }
            self.flags.moreVisible = false
        }
    }

    // MARK: Closing

    @objc private func tappedOutside() { attemptDismiss() }

    /// The user closes it: the owner may refuse (and the panel settles back).
    private func attemptDismiss(velocity: CGFloat = 0) {
        if sheet.shouldClose() { dismiss() } else { settle(to: resting, velocity: velocity) }
    }

    /// Goes down (the panel and the dim), then tells the owner.
    private func dismiss() {
        guard !closing else { return }
        closing = true
        animator?.stopAnimation(true)
        UIView.animate(withDuration: 0.24, delay: 0, options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]) {
            self.panel.transform = CGAffineTransform(translationX: 0, y: self.offscreenY)
            self.dim.alpha = 0
        } completion: { _ in
            self.sheet.close()
        }
    }

    // MARK: Finger

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer, !closing else { return true }
        let v = pan.velocity(in: view)
        return abs(v.y) > abs(v.x)
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            if animator?.isRunning == true { animator?.stopAnimation(true) }
            // `stopAnimation(true)` leaves the model value where the animation was headed; take where it is on screen.
            if let presentation = panel.layer.presentation() { panel.transform = CGAffineTransform(translationX: 0, y: presentation.affineTransform().ty) }
            panStartY = panel.transform.ty
            pan.setTranslation(.zero, in: view)
            flags.moreVisible = true
        case .changed:
            var y = panStartY + pan.translation(in: view).y
            if !sheet.canOpen { y = max(restY, y) }
            panel.transform = CGAffineTransform(translationX: 0, y: max(0, y))
            let belowRest = max(0, panel.transform.ty - extent)
            dim.alpha = 1 - min(1, belowRest / 500)
        case .ended, .cancelled:
            let v = pan.velocity(in: view).y
            let y = panel.transform.ty
            let belowRest = y - extent
            let startedAtRest = abs(panStartY - extent) < 1 || !sheet.canOpen
            if startedAtRest, belowRest > 0, belowRest > 120 || v > 600 { attemptDismiss(velocity: v); return }
            let opened: CGFloat = extent > 0 ? max(0, min(1, 1 - y / extent)) : 0
            let target: CGFloat = v < -600 ? 1 : v > 600 ? 0 : (opened > 0.5 ? 1 : 0)
            settle(to: target, velocity: v)
        default:
            break
        }
    }
}

extension PanelSheet where More == EmptyView {
    init(isOpen: Binding<Bool>, canOpen: Bool = true, close: @escaping () -> Void, @ViewBuilder content: () -> Small) {
        self.init(isOpen: isOpen, canOpen: canOpen, close: close, content: content, more: { EmptyView() })
    }
}

/// What a sheet's content calls to close its panel the way a tap outside would, with the slide down (and without the owner's `shouldClose`).
struct PanelDismiss: Sendable {
    let run: @MainActor @Sendable () -> Void
}

private struct PanelDismissKey: EnvironmentKey {
    static let defaultValue = PanelDismiss(run: {})
}

extension EnvironmentValues {
    var panelDismiss: PanelDismiss {
        get { self[PanelDismissKey.self] }
        set { self[PanelDismissKey.self] = newValue }
    }
}

private struct PanelMoreHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct PanelSmallHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
