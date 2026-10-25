import NEOBudgetCalendar
import NEOBudgetCore
import SwiftUI

/// Picks the event a transaction goes into, from the events a few days around it. Choosing one replaces whatever the transaction was linked to
/// (`ActivityEditing.link`), so the same sheet puts a transaction in and moves it.
struct TransactionEventSheet: View {
    let model: AppModel
    let transaction: TransactionMarker
    /// The activities it is in now.
    let currentActivities: Set<ActivityID>
    @Environment(\.dismiss) private var dismiss
    @State private var choices: [ActivityEditing.EventChoice]?
    @State private var failure: String?

    /// Days either side of the transaction that are searched.
    private static let reach = 3

    var body: some View {
        NavigationStack {
            Group {
                if let choices {
                    if choices.isEmpty {
                        ContentUnavailableView("근처에 일정이 없어요", systemImage: "calendar", description: Text("앞뒤 \(Self.reach)일 안의 일정만 보여요."))
                    } else {
                        list(choices)
                    }
                } else {
                    ProgressView("일정을 불러오고 있어요").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("일정에 넣기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
        }
        .task {
            let day = model.dayZone.localDate(of: transaction.occurredAtUnixMilliseconds)
            let timelines = await model.readDays((-Self.reach...Self.reach).map { day.adding(days: $0) }).compactMap(\.timeline)
            choices = ActivityEditing.eventChoices(near: transaction.occurredAtUnixMilliseconds, in: timelines)
        }
    }

    private func list(_ choices: [ActivityEditing.EventChoice]) -> some View {
        List {
            if let failure {
                Label(failure, systemImage: "exclamationmark.circle.fill").foregroundStyle(Theme.danger).font(Theme.Typo.caption).onAllCardRow()
            }
            Section {
                ForEach(choices) { choice in
                    let isCurrent = choice.activityID.map(currentActivities.contains) ?? false
                    Button {
                        Task {
                            let outcome = await model.perform(ActivityEditing.link(transaction.id, event: choice.key, now: model.nowMilliseconds))
                            if case let .rejected(reason)? = outcome { failure = "넣지 못했어요. (\(reason))" } else { dismiss() }
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                                Text(choice.title).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary)
                                Text(Formatting.shortDate(choice.startUnixMilliseconds, zoneIdentifier: model.dayZone.identifier) + " "
                                     + Formatting.timeRange(choice.startUnixMilliseconds, choice.endUnixMilliseconds, zoneIdentifier: model.dayZone.identifier))
                                    .font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary)
                            }
                            Spacer()
                            if isCurrent { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                        }
                    }
                    .disabled(isCurrent)
                    .accessibilityHint(isCurrent ? "지금 들어 있는 일정이에요" : "이 일정에 넣어요")
                }
            } footer: {
                Text("다른 일정에 들어 있던 거래는 여기로 옮겨져요.")
            }
            .onAllCardRow()
        }
        .onAllGroupedScreen()
    }
}
