import NEOBudgetCalendar
import SwiftUI

/// The user's tags: how often each is used, rename (a name that exists merges the two) and take off. Tags on events are shown but kept as they are.
struct TagManagementView: View {
    let model: AppModel
    let snapshot: AnalysisSnapshot
    @State private var renaming: String?
    @State private var newName = ""
    @State private var removing: String?

    private var tags: [(name: String, count: Int)] { AppModel.tagCounts(model.transactionOverrides) }

    var body: some View {
        List {
            Section {
                if tags.isEmpty {
                    Text("아직 붙인 태그가 없어요. 거래를 고쳐서 #태그를 붙여 보세요.").font(Theme.Typo.label).foregroundStyle(Theme.textTertiary)
                }
                ForEach(tags, id: \.name) { tag in
                    HStack {
                        Text("#" + tag.name).font(Theme.Typo.rowTitle).foregroundStyle(Theme.accent)
                        Spacer()
                        Text("\(tag.count)번").font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary)
                    }
                    .swipeActions {
                        Button("지우기") { removing = tag.name }.tint(Theme.danger)
                        Button("이름 바꾸기") { newName = tag.name; renaming = tag.name }.tint(Theme.accent)
                    }
                    .contextMenu {
                        Button("이름 바꾸기", systemImage: "pencil") { newName = tag.name; renaming = tag.name }
                        Button("지우기", systemImage: "trash", role: .destructive) { removing = tag.name }
                    }
                }
            } header: { Text("내가 붙인 태그") } footer: { Text("이름을 바꾸면 붙은 모든 거래에 바뀌어요. 이미 있는 이름으로 바꾸면 둘이 하나로 합쳐져요.") }
            .onAllCardRow()
            if !snapshot.eventTags.isEmpty {
                Section {
                    ForEach(snapshot.eventTags, id: \.name) { tag in
                        HStack {
                            Text("#" + tag.name).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Text("일정 \(tag.count)개").font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary)
                        }
                    }
                } header: { Text("일정에 붙은 태그") }
                .onAllCardRow()
            }
        }
        .onAllGroupedScreen()
        .navigationTitle("태그 관리")
        .navigationBarTitleDisplayMode(.inline)
        .alert("태그 이름 바꾸기", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("새 이름", text: $newName).textInputAutocapitalization(.never)
            Button("바꾸기") {
                if let old = renaming, let new = TransactionOverride.parseTags(newName).first, new != old { model.renameTag(old, to: new) }
            }
            Button("취소", role: .cancel) {}
        }
        .alert("태그를 지울까요?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("지우기", role: .destructive) { if let tag = removing { model.renameTag(tag, to: nil) } }
            Button("취소", role: .cancel) {}
        } message: {
            Text("거래에서 \(removing.map { "#" + $0 } ?? "")만 떼어요. 거래는 그대로예요.")
        }
    }
}
