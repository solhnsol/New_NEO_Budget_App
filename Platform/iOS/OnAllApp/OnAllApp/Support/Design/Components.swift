import SwiftUI

// The small pieces every screen is built from (`Theme` holds their values). A screen uses these instead of styling text and shapes itself.

/// The big number a screen is about, with its small gray label above (`결제한 금액` / `48,000원`).
struct AmountHero: View {
    let label: String
    let amount: String
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(label).font(Theme.Typo.label).foregroundStyle(Theme.textSecondary)
            Text(amount).font(Theme.Typo.hero).foregroundStyle(Theme.textPrimary)
            if let note { Text(note).font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Theme.Space.s)
    }
}

/// A symbol on a soft rounded tile, at the start of a row (a category, an account).
struct IconTile: View {
    let systemName: String
    var tint: Color = Theme.textSecondary
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: size * 0.32, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A short state in a pill (`아직 안 받음`, `정산 완료`).
struct StatusBadge: View {
    enum Tone { case accent, caution, neutral }

    let text: String
    var tone: Tone = .neutral

    var body: some View {
        Text(text)
            .font(Theme.Typo.badge)
            .foregroundStyle(foreground)
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, 3)
            .background(background, in: Capsule())
    }

    private var foreground: Color {
        switch tone {
        case .accent: return Theme.accent
        case .caution: return Theme.caution
        case .neutral: return Theme.textSecondary
        }
    }

    private var background: Color {
        switch tone {
        case .accent: return Theme.accentSoft
        case .caution: return Theme.cautionSoft
        case .neutral: return Theme.fill
        }
    }
}

/// The one main action of a sheet: a full-width blue button. Pinned to the bottom with `primaryActionBar`.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: Theme.primaryButtonHeight)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                    .fill(isEnabled ? Theme.accent : Theme.textTertiary.opacity(0.45))
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A quiet button on a gray tile (`다시 나누기`, `해제`).
struct SecondaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.textSecondary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.subheadline, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, 7)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var onAllPrimary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var onAllSecondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

extension View {
    /// Pins a sheet's main button to the bottom, over the screen's gray, so it is always in reach of the thumb.
    func primaryActionBar<Label: View>(isEnabled: Bool = true, action: @escaping () -> Void, @ViewBuilder label: () -> Label) -> some View {
        let label = label()
        return safeAreaInset(edge: .bottom, spacing: 0) {
            Button(action: action) { label }
                .buttonStyle(.onAllPrimary)
                .disabled(!isEnabled)
                .padding(.horizontal, Theme.Space.xl)
                .padding(.top, Theme.Space.s)
                .padding(.bottom, Theme.Space.s)
                .background(Theme.background)
        }
    }
}

/// `−  3명  +`: a count changed one at a time, with round gray buttons big enough to hit (`compact` for the row over the keyboard).
struct CountStepper: View {
    let value: Int
    let range: ClosedRange<Int>
    var unit: String = "명"
    var compact = false
    var accessibilityName: String = "인원"
    let change: (Int) -> Void

    var body: some View {
        let side: CGFloat = compact ? 28 : 34
        HStack(spacing: compact ? Theme.Space.xs : Theme.Space.s) {
            button("minus", side: side, enabled: value > range.lowerBound) { change(value - 1) }
            Text("\(value)\(unit)")
                .font(compact ? .system(.footnote, weight: .semibold).monospacedDigit() : Theme.Typo.amount)
                .foregroundStyle(Theme.textPrimary)
                .frame(minWidth: compact ? 32 : 44)
                .contentTransition(.numericText())
            button("plus", side: side, enabled: value < range.upperBound) { change(value + 1) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityName)
        .accessibilityValue("\(value)\(unit)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if value < range.upperBound { change(value + 1) }
            case .decrement: if value > range.lowerBound { change(value - 1) }
            @unknown default: break
            }
        }
    }

    private func button(_ symbol: String, side: CGFloat, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: side * 0.4, weight: .bold))
                .foregroundStyle(enabled ? Theme.textPrimary : Theme.textTertiary.opacity(0.5))
                .frame(width: side, height: side)
                .background(Theme.fill, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
