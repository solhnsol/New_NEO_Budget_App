import NEOBudgetCalendar
import NEOBudgetCore
import SwiftUI

/// Everyone the user has put on an event or a settlement, to rename, give a relationship, or forget. Opened from the ledger's toolbar.
struct PeopleListView: View {
    let model: AppModel
    @State private var people: [Person] = []
    @State private var editing: Person?
    @State private var adding = false
    @State private var newName = ""
    @State private var failure: String?

    var body: some View {
        List {
            if people.filter({ !$0.isSelf }).isEmpty {
                ContentUnavailableView("아직 등록한 사람이 없어요", systemImage: "person.2", description: Text("일정이나 정산에서 함께한 사람을 넣으면 여기에 모여요."))
                    .listRowBackground(Color.clear)
            }
            ForEach(people.filter { !$0.isSelf }, id: \.id) { person in
                Button { editing = person } label: {
                    HStack(spacing: Theme.Space.m) {
                        PersonAvatar(name: person.displayName, size: 40)
                        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                            Text(person.displayName).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary)
                            if let label = person.relationshipLabel?.value { Text(label).font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary) }
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote).foregroundStyle(Theme.textTertiary)
                    }
                }
                .swipeActions {
                    Button("지우기", role: .destructive) { remove(person) }
                }
            }
            .onAllCardRow()
        }
        .onAllGroupedScreen()
        .navigationTitle("사람")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("사람 추가") } }
        .task(id: model.dataGeneration) { await load() }
        .sheet(item: $editing) { person in PersonEditSheet(model: model, person: person) }
        .alert("사람 추가", isPresented: $adding) {
            TextField("이름", text: $newName)
            Button("추가") { add() }
            Button("취소", role: .cancel) { newName = "" }
        }
        .alert("지우지 못했어요", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private func load() async {
        let life = await model.lifeState()
        people = (life?.persons.values.sorted { $0.displayName < $1.displayName }) ?? []
    }

    private func add() {
        guard let name = ActivityEditing.cleanName(newName) else { return }
        newName = ""
        Task { await model.perform(.upsertPerson(Person(id: PersonID(rawValue: ActivityEditing.newID(prefix: "person")), displayName: name))) }
    }

    private func remove(_ person: Person) {
        Task {
            let outcome = await model.perform(.removePerson(person.id, by: ActivityEditing.provenance(now: model.nowMilliseconds)))
            if case .rejected? = outcome { failure = "\(person.displayName)님은 정산이나 요청 기록이 남아 있어서 지울 수 없어요. 기록을 모두 정리한 뒤에 지울 수 있어요." }
        }
    }
}

extension Person: @retroactive Identifiable {}

/// A person's name and relationship (친구, 가족 …). The relationship is only ever what the user says.
struct PersonEditSheet: View {
    let model: AppModel
    let person: Person
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var label: String

    private static let suggestions = ["친구", "가족", "동료", "연인"]

    init(model: AppModel, person: Person) {
        self.model = model
        self.person = person
        _name = State(initialValue: person.displayName)
        _label = State(initialValue: person.relationshipLabel?.value ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("이름") { TextField("이름", text: $name) }.onAllCardRow()
                Section("관계") {
                    TextField("친구, 가족 …", text: $label)
                    HStack {
                        ForEach(Self.suggestions, id: \.self) { suggestion in
                            PersonChipLabel(text: suggestion, isSelected: label == suggestion) { label = label == suggestion ? "" : suggestion }
                        }
                    }
                }
                .onAllCardRow()
            }
            .onAllGroupedScreen()
            .navigationTitle(person.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") { save() }.disabled(ActivityEditing.cleanName(name) == nil)
                }
            }
        }
    }

    private func save() {
        guard let cleaned = ActivityEditing.cleanName(name) else { return }
        var updated = person
        updated.displayName = cleaned
        updated.relationshipLabel = ActivityEditing.cleanName(label).map { Assigned($0, provenance: ActivityEditing.provenance(now: model.nowMilliseconds)) }
        Task {
            await model.perform(.upsertPerson(updated))
            dismiss()
        }
    }
}

/// A suggestion as a small capsule, filled when it is the current value.
private struct PersonChipLabel: View {
    let text: String
    let isSelected: Bool
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            Text(text).font(.system(.footnote, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Theme.accent : Theme.textPrimary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(isSelected ? Theme.accentSoft : Theme.fill, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
