import SwiftUI

/// Navigation value pushed when a Briefing item's "view source" row is tapped.
/// Hashable so it works with NavigationStack's value-based navigation.
struct BriefingSourceLink: Hashable {
    let recordingId: Int
    let segmentId: Int?
    let recordingTitle: String?
    let startTime: Double?
}

/// Resolves a [BriefingSourceLink] (just an ID) into a full Recording via the
/// API, then renders [SourceDetailView] with the focus segment. Used as the
/// navigationDestination handler on the Briefing tab.
struct BriefingItemSourceView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.i18n) private var i18n
    let link: BriefingSourceLink

    @State private var recording: Recording?
    @State private var loading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let rec = recording {
                SourceDetailView(recording: rec, focusSegmentId: link.segmentId)
            } else if loading {
                ProgressView()
                    .tint(DeepSenoTheme.accentGreen)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(DeepSenoTheme.bgPrimary)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28, weight: .ultraLight))
                        .foregroundStyle(DeepSenoTheme.accentRed)
                    Text(errorMessage ?? i18n.t.briefingSourceLoadFailed)
                        .font(.system(size: 13))
                        .foregroundStyle(DeepSenoTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DeepSenoTheme.bgPrimary)
            }
        }
        .task {
            await loadRecording()
        }
    }

    private func loadRecording() async {
        guard let api = appState.apiClient else {
            errorMessage = i18n.t.briefingSourceLoadFailed
            loading = false
            return
        }
        // Server doesn't expose a single-recording endpoint, so fetch the list
        // and filter locally (same approach as SourcesView). Cached responses
        // make this nearly free after the first call.
        do {
            let all = try await api.getRecordings()
            if let match = all.first(where: { $0.id == link.recordingId }) {
                recording = match
            } else {
                errorMessage = i18n.t.briefingSourceLoadFailed
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }
}
