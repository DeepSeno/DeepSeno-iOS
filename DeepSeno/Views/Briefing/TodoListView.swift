import SwiftUI

struct TodoListView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.i18n) private var i18n
    let todos: [ExtractedItem]
    let onToggle: (Int, String) -> Void

    @State private var quoteItem: ExtractedItem?

    var body: some View {
        VStack(spacing: 2) {
            ForEach(todos) { todo in
                todoRow(todo)
            }
        }
        .sheet(item: $quoteItem) { item in
            BriefingQuoteSheet(item: item)
        }
    }

    private func todoRow(_ todo: ExtractedItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // Custom checkbox
            Button {
                onToggle(todo.id, todo.status)
            } label: {
                Image(systemName: todo.isCompleted
                      ? "checkmark.square.fill"
                      : "square")
                    .font(.system(size: 18))
                    .foregroundStyle(
                        todo.isCompleted
                        ? DeepSenoTheme.accentGreen
                        : DeepSenoTheme.textSecondary
                    )
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Text(todo.content)
                    .font(DeepSenoTheme.bodyFont)
                    .foregroundStyle(
                        todo.isCompleted
                        ? DeepSenoTheme.textSecondary
                        : DeepSenoTheme.textPrimary
                    )
                    .strikethrough(todo.isCompleted)

                if let dueDate = todo.dueDate {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 10))
                        Text(dueDate)
                            .font(DeepSenoTheme.captionFont)
                    }
                    .foregroundStyle(DeepSenoTheme.accentAmber)
                }

                if todo.hasSource, let rid = todo.recordingId {
                    NavigationLink(value: BriefingSourceLink(
                        recordingId: rid,
                        segmentId: todo.segmentId,
                        recordingTitle: todo.recordingTitle,
                        startTime: todo.segmentStartTime
                    )) {
                        HStack(spacing: 6) {
                            Image(systemName: "paperclip")
                                .font(.system(size: 10))
                            Text(sourceLabel(todo))
                                .font(.system(.caption2, design: .monospaced))
                                .lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(DeepSenoTheme.accentGreen)
                        .padding(.top, 2)
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 0)

            BriefingItemMenu(item: todo, onShowQuote: { quoteItem = todo })
        }
        .padding(10)
        .background(DeepSenoTheme.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func sourceLabel(_ item: ExtractedItem) -> String {
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
}
