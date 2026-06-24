import SwiftUI

/// Shown when a user long-presses a Briefing item. Loads the segments for the
/// item's recording, picks the matching segment by id, displays its original
/// text, and offers a "View in recording" jump-to-source action.
struct BriefingQuoteSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.i18n) private var i18n
    @Environment(\.dismiss) private var dismiss

    let item: ExtractedItem

    @State private var quote: String?
    @State private var loading = true
    @State private var jumpLink: BriefingSourceLink?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                if loading {
                    HStack {
                        Spacer()
                        ProgressView()
                            .tint(DeepSenoTheme.accentGreen)
                        Spacer()
                    }
                    .padding(.vertical, 30)
                } else if let quote, !quote.isEmpty {
                    Text(quote)
                        .font(DeepSenoTheme.bodyFont)
                        .foregroundStyle(DeepSenoTheme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(DeepSenoTheme.bgSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    Text(i18n.t.briefingSourceLoadFailed)
                        .font(.system(size: 13))
                        .foregroundStyle(DeepSenoTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 20)
                }

                if let rid = item.recordingId {
                    Button {
                        jumpLink = BriefingSourceLink(
                            recordingId: rid,
                            segmentId: item.segmentId,
                            recordingTitle: item.recordingTitle,
                            startTime: item.segmentStartTime
                        )
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.forward.square")
                            Text(i18n.t.briefingViewSource)
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background(DeepSenoTheme.accentGreen)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .background(DeepSenoTheme.bgPrimary)
            .navigationTitle(i18n.t.briefingQuoteSheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(i18n.t.cancel) { dismiss() }
                        .foregroundStyle(DeepSenoTheme.textSecondary)
                }
            }
            .navigationDestination(item: $jumpLink) { link in
                BriefingItemSourceView(link: link)
            }
        }
        .task { await loadQuote() }
    }

    private func loadQuote() async {
        guard let api = appState.apiClient,
              let recordingId = item.recordingId,
              let segmentId = item.segmentId else {
            // No source attribution — fall back to content text from the item itself.
            quote = item.content
            loading = false
            return
        }
        do {
            let segments = try await api.getSegments(recordingId: recordingId)
            let match = segments.first(where: { $0.id == segmentId })
            quote = match?.displayText ?? item.content
        } catch {
            // Network error — show the item content as a poor man's "quote".
            quote = item.content
        }
        loading = false
    }
}
