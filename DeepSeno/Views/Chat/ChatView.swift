import SwiftUI

struct ChatView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.i18n) private var i18n
    private var viewModel: ChatViewModel { appState.chatVM }

    var body: some View {
        @Bindable var viewModel = viewModel
        return VStack(spacing: 0) {
            chatHeader

            // Messages or empty state
            if viewModel.messages.isEmpty && !viewModel.isStreaming {
                emptyState
            } else {
                messageList
            }

            inputBar
        }
        .background(DeepSenoTheme.bgPrimary)
        // Keyboard dismissal is handled by `.scrollDismissesKeyboard(.interactively)`
        // on the message ScrollView; an extra `.onTapGesture` here would compete
        // with the ScrollView's drag recognizer and freeze scrolling.
        .navigationBarHidden(true)
        .sheet(isPresented: $viewModel.showSessions) {
            SessionListView(viewModel: viewModel)
                .environment(appState)
        }
        .task {
            if let api = appState.apiClient {
                await viewModel.loadSessions(apiClient: api)
            }
        }
        // Consume a pending prompt set by Briefing's "Ask AI about this" action.
        .onChange(of: appState.pendingChatPrompt) { _, newValue in
            if let prompt = newValue, !prompt.isEmpty {
                viewModel.inputText = prompt
                appState.pendingChatPrompt = nil
            }
        }
        .onAppear {
            if let prompt = appState.pendingChatPrompt, !prompt.isEmpty {
                viewModel.inputText = prompt
                appState.pendingChatPrompt = nil
            }
        }
    }

    // MARK: - Header

    private var chatHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(DeepSenoTheme.accentGreen)

            VStack(alignment: .leading, spacing: 1) {
                Text(i18n.t.aiAssistant)
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                    .foregroundStyle(DeepSenoTheme.textPrimary)

                if let session = viewModel.currentSession {
                    Text(session.title)
                        .font(.system(size: 12))
                        .foregroundStyle(DeepSenoTheme.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button {
                viewModel.showSessions = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(DeepSenoTheme.textSecondary)
                    .frame(width: 36, height: 36)
                    .background(DeepSenoTheme.bgTertiary.opacity(0.6))
                    .clipShape(Circle())
            }
            .accessibilityLabel(i18n.t.a11ySessionList)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(DeepSenoTheme.bgSecondary.opacity(0.5))
        .overlay(alignment: .bottom) {
            Rectangle().fill(DeepSenoTheme.glassBorder).frame(height: 1)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "brain")
                .font(.system(size: 52, weight: .ultraLight))
                .foregroundStyle(DeepSenoTheme.textTertiary)

            Text(i18n.t.askAnything)
                .font(.system(size: 15))
                .foregroundStyle(DeepSenoTheme.textSecondary)

            // 2x3 suggestion grid
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                suggestedChip(i18n.t.suggestToday, icon: "calendar")
                suggestedChip(i18n.t.suggestMeetings, icon: "person.2")
                suggestedChip(i18n.t.suggestTasks, icon: "checkmark.circle")
                suggestedChip(i18n.t.suggestPeople, icon: "person.crop.circle")
                suggestedChip(i18n.t.suggestDecisions, icon: "hammer.fill")
                suggestedChip(i18n.t.suggestSearch, icon: "magnifyingglass")
            }
            .padding(.horizontal, 24)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func suggestedChip(_ text: String, icon: String) -> some View {
        Button {
            viewModel.inputText = text
            Task { await viewModel.sendMessage(appState: appState) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(DeepSenoTheme.accentGreen)
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(DeepSenoTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(DeepSenoTheme.bgSecondary.opacity(0.8))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(DeepSenoTheme.glassBorder, lineWidth: 1)
            )
        }
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(viewModel.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Single onChange watching both message-count and latest content.
            // Merged from two observers to avoid double rebuilds per streaming chunk.
            .onChange(of: ChatScrollKey(
                count: viewModel.messages.count,
                lastContent: viewModel.messages.last?.content
            )) { _, _ in
                scrollToBottom(proxy: proxy)
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if let lastId = viewModel.messages.last?.id {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(lastId, anchor: .bottom)
            }
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        @Bindable var viewModel = viewModel
        return HStack(spacing: 10) {
            TextField(i18n.t.askPlaceholder, text: $viewModel.inputText, axis: .vertical)
                .font(.system(size: 14))
                .foregroundStyle(DeepSenoTheme.textPrimary)
                .lineLimit(1...4)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(DeepSenoTheme.bgTertiary.opacity(0.7))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(DeepSenoTheme.glassBorder, lineWidth: 1)
                )

            Button {
                Task { await viewModel.sendMessage(appState: appState) }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(canSend ? .white : DeepSenoTheme.textTertiary)
                    .frame(width: 34, height: 34)
                    .background(canSend ? DeepSenoTheme.accentGreen : DeepSenoTheme.bgTertiary)
                    .clipShape(Circle())
            }
            .disabled(!canSend)
            .accessibilityLabel(i18n.t.a11ySendMessage)
            .animation(.easeInOut(duration: 0.15), value: canSend)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(DeepSenoTheme.bgSecondary.opacity(0.5))
        .overlay(alignment: .top) {
            Rectangle().fill(DeepSenoTheme.glassBorder).frame(height: 1)
        }
    }

    private var canSend: Bool {
        !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !viewModel.isStreaming
        && appState.isConnected
    }
}

private struct ChatScrollKey: Equatable {
    let count: Int
    let lastContent: String?
}
