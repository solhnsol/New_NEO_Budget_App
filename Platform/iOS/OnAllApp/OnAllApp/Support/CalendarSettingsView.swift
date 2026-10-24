import NEOBudgetCalendar
import SwiftUI

/// The calendars the app shows: pick each one's icon, add a calendar, delete one. Reached from 설정.
struct CalendarSettingsView: View {
    let model: AppModel
    @State private var picking: CalendarDescriptor?
    @State private var adding = false
    @State private var deleting: CalendarDescriptor?
    @State private var failure: String?

    var body: some View {
        List {
            Section {
                ForEach(model.calendars, id: \.id) { calendar in
                    row(calendar)
                        .swipeActions(edge: .trailing) {
                            if calendar.isWritable { Button("지우기", role: .destructive) { deleting = calendar }.tint(Theme.danger) }
                        }
                }
                Button { adding = true } label: {
                    HStack(spacing: Theme.Space.m) {
                        IconTile(systemName: "plus", tint: Theme.accent)
                        Text("캘린더 추가").font(Theme.Typo.rowTitle).foregroundStyle(Theme.accent)
                    }
                }
            } header: {
                Text("내 캘린더")
            } footer: {
                Text("아이콘은 리스트 보기의 일정 옆에 나와요. 밀어서 캘린더를 지울 수 있고, 구독 캘린더처럼 앱에서 바꿀 수 없는 캘린더는 지울 수 없어요.")
            }
            .onAllCardRow()
        }
        .onAllGroupedScreen()
        .navigationTitle("캘린더")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $picking) { calendar in
            CalendarIconPicker(
                title: calendar.title, color: Color(hex: calendar.colorHex) ?? Theme.accent,
                current: model.calendarSymbol(id: calendar.id, title: calendar.title)
            ) { model.setCalendarIcon($0, for: calendar.id) }
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $adding) {
            NewCalendarSheet { title, hex, symbol in
                if let message = await model.addCalendar(title: title, colorHex: hex, symbol: symbol) { failure = message; return false }
                return true
            }
            .presentationDetents([.large])
        }
        .alert("\(deleting?.title ?? "") 캘린더를 지울까요?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { calendar in
            Button("지우기", role: .destructive) { Task { failure = await model.removeCalendar(calendar.id) } }
            Button("취소", role: .cancel) {}
        } message: { _ in
            Text("이 캘린더의 일정도 모두 사라져요. 되돌릴 수 없어요.")
        }
        .alert("완료하지 못했어요", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private func row(_ calendar: CalendarDescriptor) -> some View {
        let color = Color(hex: calendar.colorHex) ?? Theme.accent
        return Button { picking = calendar } label: {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: model.calendarSymbol(id: calendar.id, title: calendar.title))
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(color)
                    .frame(width: 40, height: 40).background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text(calendar.title).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary)
                    if let detail = detail(calendar) { Text(detail).font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary) }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(.footnote, weight: .semibold)).foregroundStyle(Theme.textTertiary)
            }
        }
        .accessibilityHint("아이콘 바꾸기")
    }

    private func detail(_ calendar: CalendarDescriptor) -> String? {
        let parts = [calendar.sourceTitle, calendar.isWritable ? nil : "읽기 전용"].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

extension CalendarDescriptor: @retroactive Identifiable {}

/// A grid of icons to pick one from; picking saves it and closes the sheet.
private struct CalendarIconPicker: View {
    let title: String
    let color: Color
    let current: String
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text("\(title) 아이콘").font(Theme.Typo.title).foregroundStyle(Theme.textPrimary)
            IconGrid(selected: current, color: color) { onPick($0); dismiss() }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.xl)
        .background(Theme.background)
    }
}

private struct IconGrid: View {
    let selected: String
    let color: Color
    let onPick: (String) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Space.m), count: 4), spacing: Theme.Space.m) {
            ForEach(CalendarIcon.choices, id: \.self) { symbol in
                let on = symbol == selected
                Button { onPick(symbol) } label: {
                    Image(systemName: symbol).font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(on ? Color.white : color)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(on ? color : color.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// Name, color and icon of a calendar to make. `onCreate` returns whether it worked (the sheet stays open when it did not).
private struct NewCalendarSheet: View {
    let onCreate: (String, String, String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var colorHex = NewCalendarSheet.palette[0]
    @State private var symbol = "calendar"
    @State private var working = false
    @FocusState private var focused: Bool

    static let palette = ["#3182F6", "#F28B30", "#3FA66B", "#F04452", "#8B5CF6", "#8E8E93"]

    private var color: Color { Color(hex: colorHex) ?? Theme.accent }
    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Text("이름").font(Theme.Typo.label).foregroundStyle(Theme.textSecondary)
                        TextField("예: 운동, 스터디", text: $name)
                            .focused($focused)
                            .padding(Theme.Space.m)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                    }
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Text("색").font(Theme.Typo.label).foregroundStyle(Theme.textSecondary)
                        HStack(spacing: Theme.Space.m) {
                            ForEach(Self.palette, id: \.self) { hex in
                                Button { colorHex = hex } label: {
                                    Circle().fill(Color(hex: hex) ?? Theme.accent).frame(width: 36, height: 36)
                                        .overlay { if hex == colorHex { Image(systemName: "checkmark").font(.footnote.weight(.bold)).foregroundStyle(.white) } }
                                }
                                .accessibilityAddTraits(hex == colorHex ? .isSelected : [])
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Text("아이콘").font(Theme.Typo.label).foregroundStyle(Theme.textSecondary)
                        IconGrid(selected: symbol, color: color) { symbol = $0 }
                    }
                }
                .padding(Theme.Space.xl)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.background)
            .navigationTitle("캘린더 추가")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
            .primaryActionBar(isEnabled: !trimmed.isEmpty && !working) {
                working = true
                Task {
                    if await onCreate(trimmed, colorHex, symbol) { dismiss() }
                    working = false
                }
            } label: { Text("추가해요") }
        }
    }
}
