import Foundation

/// Identifier for the root TabView selection. Stored on AppState so non-tab
/// code (briefing items, deep links, push notifications) can switch tabs.
enum AppTab: String, Hashable, CaseIterable {
    case capture
    case sources
    case chat
    case briefing
    case settings
}
