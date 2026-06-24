import SwiftUI

struct SourcesView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.i18n) private var i18n
    private var viewModel: SourcesViewModel { appState.sourcesVM }

    private var filters: [(String, String)] {
        [
            ("all", i18n.t.filterAll),
            ("audio", i18n.t.filterVoice),
            ("video", i18n.t.filterVideo),
            ("document", i18n.t.filterDocument),
            ("image", i18n.t.filterImage),
            ("text", i18n.t.filterText),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search
            searchBar
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 6)

            // Filters
            filterChips
                .padding(.bottom, 4)

            // Content
            if viewModel.isLoading {
                Spacer()
                ProgressView()
                    .tint(DeepSenoTheme.accentGreen)
                    .scaleEffect(0.9)
                Spacer()
            } else if let results = viewModel.searchResults {
                searchResultsList(results)
            } else if viewModel.filteredRecordings.isEmpty {
                Spacer()
                EmptyStateView(
                    icon: "tray",
                    title: i18n.t.noSources,
                    subtitle: i18n.t.noSourcesSubtitle
                )
                Spacer()
            } else {
                recordingsList
            }
        }
        .background(DeepSenoTheme.bgPrimary)
        .navigationTitle(i18n.t.sources)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(DeepSenoTheme.bgSecondary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task {
            if let api = appState.apiClient {
                await viewModel.loadRecordings(apiClient: api)
            }
        }
        // Note: .refreshable is applied to the inner ScrollViews (recordingsList /
        // searchResultsList), not the outer VStack — putting it on a non-scrollable
        // container is an antipattern that can steal drag gestures on iOS 17+.
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        @Bindable var viewModel = viewModel
        return HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(DeepSenoTheme.textTertiary)

            TextField(i18n.t.searchPlaceholder, text: $viewModel.searchQuery)
                .font(.system(size: 15))
                .foregroundStyle(DeepSenoTheme.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit {
                    Task {
                        if let api = appState.apiClient {
                            await viewModel.search(apiClient: api)
                        }
                    }
                }

            if !viewModel.searchQuery.isEmpty {
                Button {
                    viewModel.searchQuery = ""
                    viewModel.searchResults = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(DeepSenoTheme.textTertiary)
                }
                .accessibilityLabel(i18n.t.a11yClearSearch)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(DeepSenoTheme.bgSecondary.opacity(0.8))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(DeepSenoTheme.glassBorder, lineWidth: 1)
        )
    }

    // MARK: - Filter Chips

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(filters, id: \.0) { filter in
                    FilterChip(
                        label: filter.1,
                        isSelected: viewModel.selectedFilter == filter.0
                    ) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            viewModel.selectedFilter = filter.0
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Recordings List

    private var recordingsList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(viewModel.filteredRecordings) { recording in
                    NavigationLink(value: recording) {
                        SourceCard(recording: recording)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .refreshable {
            if let api = appState.apiClient {
                await viewModel.loadRecordings(apiClient: api)
            }
        }
        .navigationDestination(for: Recording.self) { recording in
            SourceDetailView(recording: recording)
        }
    }

    // MARK: - Search Results

    private func searchResultsList(_ results: [SearchResult]) -> some View {
        ScrollView {
            if results.isEmpty {
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: i18n.t.noResults,
                    subtitle: i18n.t.noResultsSubtitle
                )
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(results) { result in
                        VStack(alignment: .leading, spacing: 6) {
                            if let name = result.recordingName {
                                HStack(spacing: 5) {
                                    Image(systemName: "waveform")
                                        .font(.system(size: 9))
                                    Text(name)
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundStyle(DeepSenoTheme.accentGreen)
                            }

                            Text(result.displayText)
                                .font(.system(size: 14))
                                .foregroundStyle(DeepSenoTheme.textPrimary)
                                .lineSpacing(2)
                                .lineLimit(3)

                            HStack(spacing: 8) {
                                if let speaker = result.speakerName {
                                    Label(speaker, systemImage: "person.fill")
                                        .font(.system(size: 10))
                                }
                                if let time = result.startTime {
                                    Label(formatTime(time), systemImage: "clock")
                                        .font(.system(size: 10, design: .monospaced))
                                }
                            }
                            .foregroundStyle(DeepSenoTheme.textTertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassCard(cornerRadius: 10, padding: 12)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func formatTime(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - FilterChip

private struct FilterChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .white : DeepSenoTheme.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    isSelected
                        ? DeepSenoTheme.accentGreen
                        : DeepSenoTheme.bgSecondary.opacity(0.7)
                )
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(
                            isSelected ? Color.clear : DeepSenoTheme.glassBorder,
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
    }
}
