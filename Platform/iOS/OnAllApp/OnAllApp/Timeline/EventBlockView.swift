import NEOBudgetCalendar
import SwiftUI

struct EventBlockView: View {
    let block: EventBlock
    let zoneIdentifier: String

    var body: some View {
        let color = Color(hex: block.calendarColorHex) ?? .accentColor
        let missing = block.state == .eventMissing
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                if block.continuesFromPreviousDay { Image(systemName: "arrow.up").font(.system(size: 8)) }
                Text(block.title).font(.caption.weight(.semibold)).lineLimit(2)
                if block.isRecurringInstance { Image(systemName: "repeat").font(.system(size: 8)) }
            }
            if block.endMinute - block.startMinute >= 40 {
                Text(Formatting.timeRange(block.startUnixMilliseconds, block.endUnixMilliseconds, zoneIdentifier: zoneIdentifier))
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            if let spend = block.allocatedSpend.first, block.endMinute - block.startMinute >= 60 {
                Text(Formatting.aggregate(spend)).font(.system(size: 10).weight(.medium)).foregroundStyle(.orange)
            }
            if block.continuesToNextDay { Image(systemName: "arrow.down").font(.system(size: 8)) }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(color.opacity(missing ? 0.08 : 0.22), in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 3).clipShape(RoundedRectangle(cornerRadius: 2)) }
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(color.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: missing ? [3] : [])))
        .opacity(missing ? 0.7 : 1)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(block.title), \(Formatting.timeRange(block.startUnixMilliseconds, block.endUnixMilliseconds, zoneIdentifier: zoneIdentifier))")
        .accessibilityAddTraits(.isButton)
    }
}
