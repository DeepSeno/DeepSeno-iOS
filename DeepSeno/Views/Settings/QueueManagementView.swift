import SwiftUI

struct QueueManagementView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.i18n) private var i18n

    var body: some View {
        let items = appState.captureQueue.getItems()

        List {
            if items.isEmpty {
                EmptyStateView(
                    icon: "tray",
                    title: i18n.t.queueEmpty,
                    subtitle: i18n.t.noPendingUploads
                )
                .frame(maxWidth: .infinity)
                .listRowBackground(DeepSenoTheme.bgPrimary)
                .listRowSeparator(.hidden)
            } else {
                ForEach(items, id: \.id) { item in
                    queueItemRow(item)
                        .listRowBackground(DeepSenoTheme.bgSecondary)
                        .listRowSeparatorTint(DeepSenoTheme.bgTertiary)
                }
                .onDelete { indexSet in
                    // SwiftData items can't be deleted via index easily;
                    // this is a simplified approach
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(DeepSenoTheme.bgPrimary)
        .navigationTitle(i18n.t.uploadQueue)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(i18n.t.retryAllFailed) {
                        appState.captureQueue.retryAndProcess()
                    }
                    Button(i18n.t.clearAll, role: .destructive) {
                        appState.captureQueue.clearAll()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(DeepSenoTheme.textSecondary)
                }
            }
        }
    }

    private func queueItemRow(_ item: CaptureItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: iconForType(item.type))
                .font(.system(size: 14))
                .foregroundStyle(DeepSenoTheme.textSecondary)
                .frame(width: 28, height: 28)
                .background(DeepSenoTheme.bgTertiary)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.fileName)
                    .font(DeepSenoTheme.captionFont)
                    .foregroundStyle(DeepSenoTheme.textPrimary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(item.type)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(DeepSenoTheme.textSecondary)

                    if item.retries > 0 {
                        Text("(\(item.retries) retries)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(DeepSenoTheme.accentAmber)
                    }
                }
            }

            Spacer()

            StatusBadge(status: item.status)
        }
    }

    private func iconForType(_ type: String) -> String {
        switch type {
        case "audio": "mic.fill"
        case "photo": "camera.fill"
        case "text": "text.bubble.fill"
        case "file": "doc.fill"
        default: "questionmark"
        }
    }
}
