import NEOBudgetCalendar
import NEOBudgetCore
import SwiftUI

/// The small sheet a deposit opens from the calendar: its name (editable), what it was (a category of its own), when it came, and `정산으로 처리` to put
/// it on the purchase it paid back. Built like the transaction's (`TransactionQuickSheet`): the first rows show at rest, the rest is under the fold.
struct IncomeSheet: View {
    let item: IncomeItem
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var opensCategory = false
    @State private var settling: (deposit: LedgerDeposit, life: LifeState)?
    @State private var detent = PresentationDetent.height(Self.quickHeight)
    @FocusState private var nameFocused: Bool

    static let quickHeight: CGFloat = 152
    private static let kinds = ["급여", "용돈", "이자", "환급", "기타"]

    init(item: IncomeItem, model: AppModel) {
        self.item = item
        self.model = model
        _name = State(initialValue: item.title ?? "입금")
    }

    private var override: TransactionOverride? { model.transactionOverrides[item.id] }
    private var kind: String { override?.category.flatMap { CategoryIcon.name(for: $0) } ?? "분류 안 함" }
    private var zone: String { model.dayZone.identifier }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Theme.Space.s) {
                    TextField("이름", text: $name).font(Theme.Typo.sheetTitle).foregroundStyle(Theme.textPrimary)
                        .focused($nameFocused).submitLabel(.done).onSubmit { commitName() }
                    Text("+" + Formatting.grouped(item.minorUnits) + "원").font(Theme.Typo.sheetTitle).foregroundStyle(Theme.income)
                }
                .padding(.top, Theme.Space.xl)
                VStack(spacing: 0) {
                    Button { withAnimation(Theme.Motion.sheet) { opensCategory.toggle() } } label: {
                        HStack(spacing: 0) {
                            Text("분류").foregroundStyle(Theme.textTertiary)
                            Spacer(minLength: Theme.Space.s)
                            Text(kind).foregroundStyle(Theme.textPrimary)
                            Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                                .rotationEffect(.degrees(opensCategory ? 180 : 0)).padding(.leading, Theme.Space.s)
                        }
                        .font(.onAll(size: 15)).frame(minHeight: Theme.rowHeight).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).overlay(alignment: .top) { Theme.divider.frame(height: 1) }
                    if opensCategory {
                        QuickFlow(spacing: 6) {
                            ForEach(Self.kinds, id: \.self) { name in
                                Button { setKind(name) } label: {
                                    Text(name).font(.onAll(size: 13, weight: kind == name ? .medium : .regular))
                                        .foregroundStyle(kind == name ? Theme.accentStrong : Theme.textSecondary)
                                        .padding(.horizontal, Theme.Space.m).frame(height: Theme.chipHeight)
                                        .background(kind == name ? Theme.accentSoft : Theme.fill, in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.bottom, Theme.Space.m)
                    }
                }
                .padding(.top, 6)
                VStack(spacing: 0) {
                    Color.clear.frame(height: Theme.Space.xl)
                    HStack {
                        Text("입금 시각").foregroundStyle(Theme.textTertiary)
                        Spacer()
                        Text(timeText).foregroundStyle(Theme.textPrimary)
                    }
                    .font(.onAll(size: 15)).frame(minHeight: Theme.rowHeight).overlay(alignment: .top) { Theme.divider.frame(height: 1) }
                    Button { Task { await startSettling() } } label: {
                        Text("정산으로 처리").font(.onAll(size: 16, weight: .semibold)).foregroundStyle(Theme.accentStrong)
                            .frame(maxWidth: .infinity, minHeight: Theme.primaryButtonHeight)
                            .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
                    }
                    .buttonStyle(.plain).padding(.top, Theme.Space.l)
                }
            }
            .padding(.horizontal, Theme.Space.xl).padding(.bottom, Theme.Space.l)
        }
        .scrollIndicators(.hidden)
        .background(Theme.surface)
        .tint(Theme.accent)
        .presentationDetents([.height(Self.quickHeight), .large], selection: $detent)
        .presentationCornerRadius(Theme.Radius.sheet)
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.surface)
        // A name that was typed stays however the sheet is closed.
        .onDisappear { commitName() }
        .sheet(isPresented: Binding(get: { settling != nil }, set: { if !$0 { settling = nil } })) {
            if let settling {
                DepositConfirmSheet(model: model, deposit: settling.deposit, life: settling.life, senderName: item.title ?? "")
            }
        }
    }

    private var timeText: String {
        let day = model.dayZone.localDate(of: item.occurredAtUnixMilliseconds)
        return "\(day.month)월 \(day.day)일 " + Formatting.clock24(item.occurredAtUnixMilliseconds, zoneIdentifier: zone)
    }

    private func commitName() {
        let clean = TransactionOverride.clean(name)
        guard clean != (item.title ?? "입금"), clean != nil || override?.title != nil else { return }
        var edit = override ?? TransactionOverride()
        edit.title = clean == (item.title) ? nil : clean
        model.edit(item.id, to: edit)
    }

    private func setKind(_ name: String) {
        var edit = override ?? TransactionOverride()
        edit.category = CanonicalCategoryID(rawValue: name)
        model.edit(item.id, to: edit)
    }

    /// The deposit goes through the settlement flow the ledger has (`DepositConfirmSheet`): which request it pays, and what is left.
    private func startSettling() async {
        guard let money = try? Money(minorUnits: item.minorUnits, currency: "KRW"), let life = await model.lifeState() else { return }
        settling = (LedgerDeposit(id: item.id, occurredAtUnixMilliseconds: item.occurredAtUnixMilliseconds, amount: money, title: item.title), life)
    }
}
