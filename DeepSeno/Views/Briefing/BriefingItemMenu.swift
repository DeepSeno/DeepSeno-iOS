import SwiftUI

/// Trailing-edge "…" button on each Briefing item. Opens a small Menu with
/// "View quote" (when source available) and "Ask AI about this".
///
/// Why a tap-menu instead of `.contextMenu`: long-press on every row inside a
/// scrolling list competes with the user's vertical drag, making the list feel
/// like it can't scroll. An explicit button has zero gesture conflict.
struct BriefingItemMenu: View {
    @Environment(AppState.self) private var appState
    @Environment(\.i18n) private var i18n
    let item: ExtractedItem
    let onShowQuote: () -> Void

    var body: some View {
        Menu {
            if item.hasSource {
                Button {
                    onShowQuote()
                } label: {
                    Label(i18n.t.briefingQuoteSheetTitle, systemImage: "quote.opening")
                }
            }
            Button {
                askAI()
            } label: {
                Label(i18n.t.briefingAskAI, systemImage: "bubble.left.and.text.bubble.right")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DeepSenoTheme.textTertiary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(i18n.t.briefingMoreActions)
    }

    private func askAI() {
        appState.pendingChatPrompt = String(
            format: i18n.t.briefingAskAIPrefixFormat,
            item.content
        )
        appState.selectedTab = .chat
    }
}
