import SwiftUI

struct SessionListView: View {
    @Bindable var viewModel: ChatViewModel
    @Environment(AppState.self) private var appState
    @Environment(\.i18n) private var i18n
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // New session button
                Button {
                    Task {
                        if let api = appState.apiClient {
                            await viewModel.createSession(apiClient: api)
                            dismiss()
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(DeepSenoTheme.accentGreen)
                        Text(i18n.t.newSession)
                            .font(DeepSenoTheme.bodyFont)
                            .foregroundStyle(DeepSenoTheme.accentGreen)
                    }
                }
                .listRowBackground(DeepSenoTheme.bgSecondary)

                // Existing sessions
                ForEach(viewModel.sessions) { session in
                    Button {
                        Task {
                            if let api = appState.apiClient {
                                await viewModel.switchSession(id: session.id, apiClient: api)
                                dismiss()
                            }
                        }
                    } label: {
                        sessionRow(session)
                    }
                    .listRowBackground(
                        viewModel.currentSession?.id == session.id
                        ? DeepSenoTheme.bgTertiary : DeepSenoTheme.bgSecondary
                    )
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        let session = viewModel.sessions[index]
                        if let api = appState.apiClient {
                            viewModel.deleteSession(id: session.id, apiClient: api)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(DeepSenoTheme.bgPrimary)
            .navigationTitle(i18n.t.sessions)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(i18n.t.done) { dismiss() }
                        .font(DeepSenoTheme.bodyFont)
                        .foregroundStyle(DeepSenoTheme.accentGreen)
                }
            }
            .toolbarBackground(DeepSenoTheme.bgSecondary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .presentationDetents([.medium, .large])
    }

    private func sessionRow(_ session: ChatSession) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.title)
                .font(DeepSenoTheme.bodyFont)
                .foregroundStyle(DeepSenoTheme.textPrimary)
                .lineLimit(1)

            Text(formatDate(session.updatedAt ?? ""))
                .font(DeepSenoTheme.captionFont)
                .foregroundStyle(DeepSenoTheme.textSecondary)
        }
        .padding(.vertical, 4)
    }

    private func formatDate(_ dateString: String) -> String {
        // Try ISO 8601 parsing
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: dateString) {
            let relative = RelativeDateTimeFormatter()
            relative.unitsStyle = .short
            return relative.localizedString(for: date, relativeTo: Date())
        }
        // Fallback — return raw string trimmed
        return String(dateString.prefix(10))
    }
}
