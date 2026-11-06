import NEOBudgetCalendar
import NEOBudgetCore
import SwiftUI

extension View {
    /// The sheets of selection mode (분류, 태그): the common sheet look, without the grabber.
    func onAllSelectionSheet() -> some View {
        presentationDetents([.medium, .large])
            .presentationCornerRadius(Theme.Radius.sheet)
            .presentationDragIndicator(.hidden)
            .presentationBackground(Theme.surface)
    }
}

/// 분류: one of the app's fixed categories, applied to every picked transaction at once. There is no way to add a category here.
struct LedgerCategorySheet: View {
    let count: Int
    let apply: (CanonicalCategoryID) -> Void
    @State private var chosen: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack {
                Text("분류").font(Theme.Typo.sheetTitle).foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("\(count)건").font(Theme.Typo.label).foregroundStyle(Theme.textTertiary)
            }
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Space.m), count: 4), spacing: Theme.Space.m) {
                    ForEach(CategoryIcon.choices, id: \.id) { choice in
                        let isChosen = chosen == choice.id
                        Button { chosen = choice.id } label: {
                            VStack(spacing: 6) {
                                let tile = LedgerTile.of(CanonicalCategoryID(rawValue: choice.id))
                                LineIcon(name: tile.icon, size: 24).foregroundStyle(Theme.textSecondary)
                                    .frame(width: 52, height: 52)
                                    .background(tile.tint, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(isChosen ? Theme.accent : .clear, lineWidth: 2))
                                Text(choice.name).font(isChosen ? Font.onAll(size: 13, weight: .semibold) : Theme.Typo.label)
                                    .foregroundStyle(isChosen ? Theme.textPrimary : Theme.textSecondary).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isChosen ? .isSelected : [])
                    }
                }
            }
            Button("\(count)건에 적용") { if let chosen { apply(CanonicalCategoryID(rawValue: chosen)) } }
                .buttonStyle(.onAllPrimary)
                .disabled(chosen == nil)
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.top, Theme.Space.xl)
        .padding(.bottom, Theme.Space.s)
    }
}

/// 태그: pick tags already in use or type a new one; every picked transaction gets all the chosen tags (what it had stays).
struct LedgerTagSheet: View {
    let count: Int
    let known: [String]
    let apply: ([String]) -> Void
    @State private var chosen: [String] = []
    @State private var extra: [String] = []
    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack {
                Text("태그").font(Theme.Typo.sheetTitle).foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("\(count)건").font(Theme.Typo.label).foregroundStyle(Theme.textTertiary)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: Theme.Space.s, alignment: .leading)], alignment: .leading, spacing: Theme.Space.s) {
                    ForEach(extra + known.filter { !extra.contains($0) }, id: \.self) { tag in
                        let isChosen = chosen.contains(tag)
                        Button { if isChosen { chosen.removeAll { $0 == tag } } else { chosen.append(tag) } } label: {
                            Text(tag).font(Theme.Typo.chip)
                                .foregroundStyle(isChosen ? Theme.accentStrong : Theme.textSecondary)
                                .padding(.horizontal, Theme.Space.m)
                                .frame(height: 36)
                                .background(isChosen ? Theme.accentSoft : Theme.fill, in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isChosen ? .isSelected : [])
                    }
                }
            }
            HStack {
                LineIcon(name: "tag", size: 18).foregroundStyle(Theme.textTertiary)
                TextField("", text: $typed, prompt: Text("태그 추가").foregroundStyle(Theme.disabled)).submitLabel(.done).onSubmit(add)
            }
            .padding(.horizontal, Theme.Space.m)
            .frame(height: 44)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.Radius.smallButton, style: .continuous))
            Button("\(count)건에 적용") { apply(chosen) }
                .buttonStyle(.onAllPrimary)
                .disabled(chosen.isEmpty)
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.top, Theme.Space.xl)
        .padding(.bottom, Theme.Space.s)
    }

    private func add() {
        for tag in TransactionOverride.parseTags(typed) where !chosen.contains(tag) {
            if !known.contains(tag) && !extra.contains(tag) { extra.append(tag) }
            chosen.append(tag)
        }
        typed = ""
    }
}
