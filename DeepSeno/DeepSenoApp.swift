import SwiftUI
import SwiftData

@main
struct DeepSenoApp: App {
    @State private var appState = AppState()
    @State private var i18n = I18nManager()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        TranscriptCorrector.runSelfChecks()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .environment(\.i18n, i18n)
                .preferredColorScheme(.dark)
        }
        .modelContainer(for: [CaptureItem.self, CachedRecording.self, CachedBriefing.self])
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                if let api = appState.apiClient {
                    Task { await appState.captureQueue.processQueue(apiClient: api) }
                }
                // 未连接时跑完整自动重连(会先试上次 IP,失败则 Bonjour 发现)
                if !appState.webSocket.isConnected {
                    Task { @MainActor in await appState.reconnectIfPossible() }
                }
            }
        }
    }
}
