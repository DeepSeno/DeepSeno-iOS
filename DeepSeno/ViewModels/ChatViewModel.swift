import SwiftUI

struct DisplayMessage: Identifiable {
    let id: String
    var role: String
    var content: String
    var isStreaming: Bool = false
    var sources: [StreamingMessage.Source] = []

    var isUser: Bool { role == "user" }

    init(id: String = UUID().uuidString, role: String, content: String,
         isStreaming: Bool = false, sources: [StreamingMessage.Source] = []) {
        self.id = id
        self.role = role
        self.content = content
        self.isStreaming = isStreaming
        self.sources = sources
    }

    init(from message: ChatMessage) {
        self.id = "\(message.id)"
        self.role = message.role
        self.content = message.content
        self.isStreaming = false

        if let json = message.sourcesJson,
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([StreamingMessage.Source].self, from: data) {
            self.sources = decoded
        } else {
            self.sources = []
        }
    }
}

@Observable
class ChatViewModel: @unchecked Sendable {
    var messages: [DisplayMessage] = []
    var sessions: [ChatSession] = []
    var currentSession: ChatSession?
    var inputText: String = ""
    var isStreaming: Bool = false
    var showSessions: Bool = false
    var errorMessage: String?

    private var streamingMessageId: String?

    // MARK: - Sessions

    func loadSessions(apiClient: APIClient) async {
        do {
            sessions = try await apiClient.getChatSessions()
            if currentSession == nil, let first = sessions.first {
                currentSession = first
                await loadMessages(apiClient: apiClient)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createSession(apiClient: APIClient) async {
        do {
            let session = try await apiClient.createChatSession()
            sessions.insert(session, at: 0)
            currentSession = session
            messages = []
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func switchSession(id: Int, apiClient: APIClient) async {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        currentSession = session
        await loadMessages(apiClient: apiClient)
    }

    func deleteSession(id: Int, apiClient: APIClient) {
        sessions.removeAll { $0.id == id }
        if currentSession?.id == id {
            currentSession = sessions.first
            if let api = apiClient as APIClient? {
                Task { await loadMessages(apiClient: api) }
            }
        }
    }

    // MARK: - Messages

    func loadMessages(apiClient: APIClient) async {
        guard let session = currentSession else {
            messages = []
            return
        }
        do {
            let serverMessages = try await apiClient.getSessionMessages(sessionId: session.id)
            messages = serverMessages.map { DisplayMessage(from: $0) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Send

    func sendMessage(appState: AppState) async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        guard let host = appState.connectionHost,
              let port = appState.connectionPort,
              let token = appState.connectionToken else { return }
        let secure = appState.connectionSecure
        let fingerprint = appState.connectionFingerprint

        Haptics.light()
        inputText = ""
        errorMessage = nil

        // Append user message
        let userMsg = DisplayMessage(role: "user", content: text)
        messages.append(userMsg)

        // Create session if needed
        if currentSession == nil, let api = appState.apiClient {
            do {
                let session = try await api.createChatSession()
                sessions.insert(session, at: 0)
                currentSession = session
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }

        // Append streaming assistant message
        let assistantId = UUID().uuidString
        streamingMessageId = assistantId
        let assistantMsg = DisplayMessage(id: assistantId, role: "assistant", content: "", isStreaming: true)
        messages.append(assistantMsg)
        isStreaming = true

        do {
            let sessionId = currentSession?.id
            let sources = try await appState.sseClient.queryStream(
                host: host,
                port: port,
                token: token,
                secure: secure,
                fingerprint: fingerprint,
                question: text,
                sessionId: sessionId,
                onChunk: { [weak self] chunk in
                    Task { @MainActor in
                        self?.appendChunk(chunk, messageId: assistantId)
                    }
                },
                onStatus: { _ in }
            )

            // Finalize the message
            if let idx = messages.firstIndex(where: { $0.id == assistantId }) {
                messages[idx].isStreaming = false
                messages[idx].sources = sources
            }
        } catch {
            if let idx = messages.firstIndex(where: { $0.id == assistantId }) {
                messages[idx].content = String(format: AppLanguage.current == .zh ? "错误：%@" : "Error: %@", error.localizedDescription)
                messages[idx].isStreaming = false
            }
        }

        isStreaming = false
        streamingMessageId = nil
    }

    private func appendChunk(_ chunk: String, messageId: String) {
        if let idx = messages.firstIndex(where: { $0.id == messageId }) {
            messages[idx].content += chunk
        }
    }
}
