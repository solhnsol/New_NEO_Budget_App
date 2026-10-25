import SwiftUI

/// The tags on a transaction as chips, with a field to add one and the tags used before offered underneath, so the same tag is spelled the same way.
struct TagField: View {
    @Binding var tags: [String]
    let suggestions: [String]
    @State private var draft = ""

    private var offered: [String] { suggestions.filter { !tags.contains($0) }.prefix(8).map { $0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if !tags.isEmpty {
                FlowLayout(spacing: Theme.Space.s) {
                    ForEach(tags, id: \.self) { tag in
                        Button { withAnimation(.snappy(duration: 0.2)) { tags.removeAll { $0 == tag } } } label: {
                            HStack(spacing: 4) {
                                Text("#" + tag)
                                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            }
                            .font(Theme.Typo.badge).foregroundStyle(Theme.accent)
                            .padding(.horizontal, Theme.Space.m).padding(.vertical, 6)
                            .background(Theme.accentSoft, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(tag) 태그 지우기")
                    }
                }
            }
            TextField("#태그 쓰고 완료 누르기", text: $draft)
                .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.done)
                .onSubmit(commit)
                .onChange(of: draft) { _, value in if value.last == " " || value.last == "," { commit() } }
            if !offered.isEmpty {
                FlowLayout(spacing: Theme.Space.s) {
                    ForEach(offered, id: \.self) { tag in
                        Button { withAnimation(.snappy(duration: 0.2)) { tags.append(tag) } } label: {
                            Text("#" + tag).font(Theme.Typo.badge).foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, Theme.Space.m).padding(.vertical, 6)
                                .background(Theme.fill, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .onDisappear(perform: commit)
    }

    private func commit() {
        for tag in TransactionOverride.parseTags(draft) where !tags.contains(tag) { tags.append(tag) }
        draft = ""
    }
}

/// Chips that wrap onto the next line when the row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + rowHeight), origins)
    }
}
