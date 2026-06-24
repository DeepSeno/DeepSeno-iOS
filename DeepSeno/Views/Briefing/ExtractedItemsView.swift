import SwiftUI

struct ExtractedItemsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.i18n) private var i18n
    let items: [ExtractedItem]

    @State private var quoteItem: ExtractedItem?

    private var groupedItems: [(String, [ExtractedItem])] {
        let groups = Dictionary(grouping: items) { $0.type }
        let order = ["decision", "contact", "meeting", "memo", "number"]
        return order.compactMap { type in
            guard let group = groups[type], !group.isEmpty else { return nil }
            return (type, group)
        } + groups.filter { !order.contains($0.key) }.map { ($0.key, $0.value) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(groupedItems, id: \.0) { type, groupItems in
                VStack(alignment: .leading, spacing: 6) {
                    // Section header with type badge
                    typeBadge(type)

                    ForEach(groupItems) { item in
                        itemRow(item)
                    }
                }
            }
        }
        .sheet(item: $quoteItem) { item in
            BriefingQuoteSheet(item: item)
        }
    }

    private func typeBadge(_ type: String) -> some View {
        Text(type.uppercased())
            .font(.system(.caption2, design: .monospaced))
            .fontWeight(.medium)
            .foregroundStyle(colorForType(type))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(colorForType(type).opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func itemRow(_ item: ExtractedItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(colorForType(item.type))
                    .frame(width: 6, height: 6)
                    .padding(.top, 6)

                Text(item.content)
                    .font(DeepSenoTheme.bodyFont)
                    .foregroundStyle(DeepSenoTheme.textPrimary)

                Spacer()

                if item.priority == "urgent" {
                    Text(i18n.t.priorityUrgent)
                        .font(.system(.caption2, design: .monospaced))
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.red)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                } else if item.priority == "low" {
                    Text(i18n.t.priorityLow)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(DeepSenoTheme.textTertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(DeepSenoTheme.bgTertiary)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }

                BriefingItemMenu(item: item, onShowQuote: { quoteItem = item })
            }

            if let assignee = item.assignee, !assignee.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "person.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(DeepSenoTheme.textTertiary)
                    Text(assignee)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(DeepSenoTheme.textSecondary)
                }
                .padding(.leading, 14)
            }

            if item.hasSource {
                sourceLinkRow(item)
            }
        }
        .padding(10)
        .background(DeepSenoTheme.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// "📎 From «xxx» · 12:34 →" row that pushes a BriefingSourceLink onto the
    /// NavigationStack. Only shown when item.recordingId is non-nil.
    @ViewBuilder
    private func sourceLinkRow(_ item: ExtractedItem) -> some View {
        if let rid = item.recordingId {
            NavigationLink(value: BriefingSourceLink(
                recordingId: rid,
                segmentId: item.segmentId,
                recordingTitle: item.recordingTitle,
                startTime: item.segmentStartTime
            )) {
                HStack(spacing: 6) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 10))
                    Text(sourceLinkLabel(item))
                        .font(.system(.caption2, design: .monospaced))
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(DeepSenoTheme.accentGreen)
                .padding(.leading, 14)
                .padding(.top, 2)
            }
            .buttonStyle(.plain)
        }
    }

    private func sourceLinkLabel(_ item: ExtractedItem) -> String {
        let title = item.recordingTitle?.isEmpty == false
            ? item.recordingTitle!
            : i18n.t.briefingViewSource
        if let t = item.segmentStartTime {
            let m = Int(t) / 60
            let s = Int(t) % 60
            return String(format: "%@ · %d:%02d", title, m, s)
        }
        return title
    }

    private func colorForType(_ type: String) -> Color {
        switch type {
        case "decision": DeepSenoTheme.accentAmber
        case "contact": DeepSenoTheme.accentBlue
        case "meeting": Color(hex: 0xa855f7) // purple
        case "number": DeepSenoTheme.textSecondary
        case "memo": Color(hex: 0x14b8a6) // teal
        default: DeepSenoTheme.textSecondary
        }
    }
}
