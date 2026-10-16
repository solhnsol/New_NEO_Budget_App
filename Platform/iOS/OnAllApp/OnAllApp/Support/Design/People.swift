import NEOBudgetCalendar
import SwiftUI

/// What a person is drawn as: a soft colored circle with their name in it, the way Korean messengers and Toss show friends. Korean names show
/// the given name (`김민수` → `민수`), other names their first letter. The color comes from the name, so a person keeps theirs everywhere.
struct PersonAvatar: View {
    let name: String
    var size: CGFloat = 44
    var isSelf = false
    var isSelected = false

    var body: some View {
        let tint = isSelf ? Theme.accent : Self.tint(for: name)
        Text(isSelf ? "나" : Self.monogram(name))
            .font(.system(size: size * (Self.monogram(name).count > 1 && !isSelf ? 0.3 : 0.4), weight: .bold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: size, height: size)
            .background(tint.opacity(0.16), in: Circle())
            .overlay(alignment: .bottomTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: size * 0.38))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Theme.accent)
                        .background(Circle().fill(Theme.surface).padding(1))
                        .offset(x: 2, y: 2)
                }
            }
            .accessibilityHidden(true)
    }

    /// `김민수` → `민수`, `민수` → `민수`, `Alex` → `A`.
    static func monogram(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.unicodeScalars.first else { return "?" }
        let isHangul = (0xAC00...0xD7A3).contains(first.value)
        if isHangul {
            let letters = Array(trimmed.filter { !$0.isWhitespace })
            return letters.count >= 3 ? String(letters.suffix(2)) : String(letters)
        }
        return String(trimmed.prefix(1)).uppercased()
    }

    private static let tints: [Color] = [
        .dynamic(light: 0xFF7E36, dark: 0xFF9A5E), // 당근 orange
        .dynamic(light: 0x2AC1BC, dark: 0x4FD6D1), // 배민 mint
        .dynamic(light: 0x8B5CF6, dark: 0xA78BFA),
        .dynamic(light: 0xEC4899, dark: 0xF472B6),
        .dynamic(light: 0x16A34A, dark: 0x4ADE80),
        .dynamic(light: 0xCA8A04, dark: 0xFACC15),
    ]

    /// The same color for the same name on every launch (`hashValue` changes between launches, so the scalars are summed).
    static func tint(for name: String) -> Color {
        let sum = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return tints[sum % tints.count]
    }
}

/// A person as a small chip, for the row over the keyboard: a tiny avatar and the name, filled blue when chosen.
struct PersonChip: View {
    let name: String
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 5) {
                PersonAvatar(name: name, size: 20)
                Text(name).font(.system(.footnote, weight: isSelected ? .semibold : .regular)).lineLimit(1)
            }
            .foregroundStyle(isSelected ? Theme.accent : Theme.textPrimary)
            .padding(.leading, 4).padding(.trailing, 10).padding(.vertical, 4)
            .background(isSelected ? Theme.accentSoft : Theme.fill, in: Capsule())
            .overlay(Capsule().strokeBorder(isSelected ? Theme.accent.opacity(0.6) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Who was there, as faces in a row: the user first (always there), then everyone known, tapped to put in or take out, then `추가` for someone new.
/// Used wherever people are chosen (an event's details, its settlement), so choosing people looks and works the same everywhere.
struct PeoplePicker: View {
    let people: [ActivityCatalog.Person]
    let chosen: Set<PersonID>
    var isLocked = false
    let toggle: (PersonID) -> Void
    let add: (String) -> Void

    @State private var isAdding = false
    @State private var newName = ""

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                tile(name: "나", avatar: PersonAvatar(name: "나", size: 48, isSelf: true, isSelected: true), dimmed: false)
                    .accessibilityLabel("나, 항상 포함")
                ForEach(people.filter { !$0.isSelf }) { person in
                    let on = chosen.contains(person.id)
                    Button { toggle(person.id) } label: {
                        tile(name: person.name, avatar: PersonAvatar(name: person.name, size: 48, isSelected: on), dimmed: !on)
                    }
                    .buttonStyle(.plain)
                    .disabled(isLocked)
                    .accessibilityLabel(person.name)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
                if !isLocked {
                    Button { isAdding = true } label: {
                        tile(name: "추가", avatar: addCircle, dimmed: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("사람 추가")
                }
            }
            .padding(.vertical, Theme.Space.xs)
        }
        .alert("누구와 함께했나요?", isPresented: $isAdding) {
            TextField("이름", text: $newName)
            Button("취소", role: .cancel) { newName = "" }
            Button("추가") {
                if let name = ActivityEditing.cleanName(newName) { add(name) }
                newName = ""
            }
        } message: {
            Text("한 번 추가한 사람은 다음 일정에서도 바로 고를 수 있어요.")
        }
    }

    private var addCircle: some View {
        Image(systemName: "plus")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .frame(width: 48, height: 48)
            .background(Theme.fill, in: Circle())
    }

    private func tile(name: String, avatar: some View, dimmed: Bool) -> some View {
        VStack(spacing: Theme.Space.xs) {
            avatar.opacity(dimmed ? 0.45 : 1)
            Text(name)
                .font(.system(.caption, weight: dimmed ? .regular : .semibold))
                .foregroundStyle(dimmed ? Theme.textTertiary : Theme.textPrimary)
                .lineLimit(1)
        }
        .frame(width: 56)
        .contentShape(Rectangle())
    }
}

/// `총 인원  −  4명  +` with what it means underneath: the user is counted, and people without a name can be counted too.
struct HeadcountRow: View {
    let value: Int
    let least: Int
    var isLocked = false
    let change: (Int) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text("총 인원").font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary)
                Text(value > least ? "이름 없는 \(value - least)명 포함, 나도 포함이에요" : "나도 포함이에요")
                    .font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: Theme.Space.s)
            CountStepper(value: value, range: least...50, accessibilityName: "총 인원", change: change)
                .disabled(isLocked)
        }
        .padding(.vertical, Theme.Space.xs)
    }
}
