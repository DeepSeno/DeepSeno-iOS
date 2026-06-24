import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.i18n) private var i18n
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        @Bindable var appState = appState
        TabView(selection: $appState.selectedTab) {
            CaptureView()
                .tabItem { Label(i18n.t.tabCapture, systemImage: "mic.fill") }
                .tag(AppTab.capture)

            NavigationStack {
                SourcesView()
            }
            .tabItem { Label(i18n.t.tabSources, systemImage: "tray.full.fill") }
            .tag(AppTab.sources)

            NavigationStack {
                ChatView()
            }
            .tabItem { Label(i18n.t.tabAI, systemImage: "brain") }
            .tag(AppTab.chat)

            BriefingView()
                .tabItem { Label(i18n.t.tabBriefing, systemImage: "doc.text") }
                .tag(AppTab.briefing)

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label(i18n.t.tabSettings, systemImage: "gearshape") }
            .tag(AppTab.settings)
        }
        .tint(DeepSenoTheme.accentGreen)
        .onAppear {
            appState.setModelContext(modelContext)
            configureTabBar()
        }
    }

    private func configureTabBar() {
        let tabBarAppearance = UITabBarAppearance()
        tabBarAppearance.configureWithOpaqueBackground()
        tabBarAppearance.backgroundColor = UIColor(DeepSenoTheme.bgSecondary)

        // Subtle top border
        tabBarAppearance.shadowColor = UIColor(white: 1.0, alpha: 0.04)

        // Selected state
        let selectedAppearance = UITabBarItemAppearance()
        selectedAppearance.normal.iconColor = UIColor(DeepSenoTheme.textSecondary)
        selectedAppearance.normal.titleTextAttributes = [
            .font: UIFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: UIColor(DeepSenoTheme.textSecondary),
        ]
        selectedAppearance.selected.iconColor = UIColor(DeepSenoTheme.accentGreen)
        selectedAppearance.selected.titleTextAttributes = [
            .font: UIFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: UIColor(DeepSenoTheme.accentGreen),
        ]

        tabBarAppearance.stackedLayoutAppearance = selectedAppearance
        tabBarAppearance.inlineLayoutAppearance = selectedAppearance
        tabBarAppearance.compactInlineLayoutAppearance = selectedAppearance

        UITabBar.appearance().standardAppearance = tabBarAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabBarAppearance
    }
}

struct PlaceholderView: View {
    let title: String
    let icon: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 48, weight: .ultraLight))
                .foregroundStyle(DeepSenoTheme.textTertiary)
            Text(title)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(DeepSenoTheme.textPrimary)
            Text("Coming Soon")
                .font(.system(size: 14))
                .foregroundStyle(DeepSenoTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DeepSenoTheme.bgPrimary)
    }
}
