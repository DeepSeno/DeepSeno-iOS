import SwiftUI

struct BriefingView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.i18n) private var i18n
    private var viewModel: BriefingViewModel { appState.briefingVM }
    @State private var calendarExpanded = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Mode picker
                modePicker

                // Date navigation
                dateNav

                Divider().overlay(DeepSenoTheme.bgTertiary)

                // Content
                if viewModel.isLoading {
                    loadingView
                } else if viewModel.mode == .daily {
                    dailyContent
                } else {
                    weeklyContent
                }
            }
            .background(DeepSenoTheme.bgPrimary)
            .navigationTitle(i18n.t.briefing)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(DeepSenoTheme.bgSecondary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationDestination(for: BriefingSourceLink.self) { link in
                BriefingItemSourceView(link: link)
            }
        }
        .task {
            await loadIfConnected()
        }
        .onChange(of: viewModel.selectedDate) { _, _ in
            Task { await loadIfConnected() }
        }
        .onChange(of: viewModel.mode) { _, _ in
            Task { await loadIfConnected() }
        }
    }

    // MARK: - Mode Picker

    private var modePicker: some View {
        @Bindable var viewModel = viewModel
        return Picker("Mode", selection: $viewModel.mode) {
            Text(i18n.t.daily).tag(BriefingViewModel.ViewMode.daily)
            Text(i18n.t.weekly).tag(BriefingViewModel.ViewMode.weekly)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(DeepSenoTheme.bgSecondary)
    }

    // MARK: - Date Navigation

    private var dateNav: some View {
        @Bindable var viewModel = viewModel
        return VStack(spacing: 0) {
            HStack {
                Button {
                    viewModel.previousDate()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(DeepSenoTheme.textSecondary)
                        .frame(width: 32, height: 32)
                }

                Spacer()

                // Tappable date / week — expands a graphical month calendar
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        calendarExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(viewModel.mode == .daily
                             ? viewModel.displayDate
                             : viewModel.weekDisplayRange)
                            .font(DeepSenoTheme.headlineFont)
                            .foregroundStyle(DeepSenoTheme.textPrimary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(DeepSenoTheme.textTertiary)
                            .rotationEffect(.degrees(calendarExpanded ? 180 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()

                Button { viewModel.nextDate() } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(DeepSenoTheme.textSecondary)
                        .frame(width: 32, height: 32)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            if calendarExpanded {
                calendarDropdown(viewModel: viewModel)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity
                    ))
            }
        }
        .background(DeepSenoTheme.bgSecondary)
    }

    // MARK: - Calendar Dropdown

    /// Custom month grid with per-day activity indicators. Long-press a day
    /// to peek at its summary / recording count without leaving the calendar.
    @ViewBuilder
    private func calendarDropdown(viewModel: BriefingViewModel) -> some View {
        MonthCalendarView(
            selectedDate: Binding(
                get: { viewModel.selectedDate },
                set: { newDate in
                    viewModel.selectedDate = newDate
                    withAnimation(.easeInOut(duration: 0.25)) {
                        calendarExpanded = false
                    }
                }
            ),
            activities: viewModel.calendarActivity,
            locale: i18n.lang.locale,
            onDisplayedMonthChange: { month in
                if let api = appState.apiClient {
                    Task { await viewModel.loadCalendarActivity(forMonthContaining: month, apiClient: api) }
                }
            }
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .task {
            if let api = appState.apiClient {
                await viewModel.loadCalendarActivity(forMonthContaining: viewModel.selectedDate, apiClient: api)
            }
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack {
            Spacer()
            ProgressView()
                .tint(DeepSenoTheme.accentGreen)
            Text(i18n.t.loading)
                .font(DeepSenoTheme.captionFont)
                .foregroundStyle(DeepSenoTheme.textSecondary)
                .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Daily Content

    private var dailyContent: some View {
        let summaryText = viewModel.dailySummary?.summaryText
        let hasSummary = !(summaryText?.isEmpty ?? true)
        // Briefing intentionally excludes todos — they belong in a future
        // dedicated Tasks view, not in the AI digest.
        let nonTodoItems = viewModel.items.filter { !$0.isTodo }
        let totallyEmpty = !hasSummary && nonTodoItems.isEmpty

        return ScrollView {
            // Plain VStack (not Lazy) — briefing pages have small item counts
            // and LazyVStack has occasional height-reporting bugs that break
            // scrolling when combined with nested per-row gestures.
            VStack(alignment: .leading, spacing: 16) {
                if let gen = viewModel.dailySummary?.generatedAt,
                   let ago = RelativeTime.ago(from: gen, locale: i18n.lang) {
                    generatedAtRow(ago)
                }

                if hasSummary {
                    summaryHeroCard(summaryText ?? "")
                } else if !totallyEmpty {
                    // Items exist but no narrative — explain why instead of
                    // letting the page feel like a bare extracted-item list.
                    noNarrativePlaceholder
                }

                if !nonTodoItems.isEmpty {
                    sectionHeaderWithCount(i18n.t.extractedHeader, count: nonTodoItems.count)
                    ExtractedItemsView(items: nonTodoItems)
                }

                if totallyEmpty {
                    EmptyStateView(
                        icon: "doc.text",
                        title: i18n.t.noBriefing,
                        subtitle: i18n.t.noBriefingSubtitle
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                }
            }
            .padding(16)
            .padding(.bottom, 32) // ensure last row clears the tab bar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .refreshable {
            await loadIfConnected()
        }
    }

    @ViewBuilder
    private func summaryHeroCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DeepSenoTheme.accentGreen)
                Text(i18n.t.summaryHeader)
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.semibold)
                    .foregroundStyle(DeepSenoTheme.accentGreen)
                    .tracking(1)
            }
            Text(text)
                .font(.system(size: 15))
                .lineSpacing(4)
                .foregroundStyle(DeepSenoTheme.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(DeepSenoTheme.accentGreen.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(DeepSenoTheme.accentGreen.opacity(0.25), lineWidth: 1)
                )
        )
    }

    private var noNarrativePlaceholder: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hourglass")
                    .font(.system(size: 12))
                    .foregroundStyle(DeepSenoTheme.textTertiary)
                Text(i18n.t.briefingNoNarrativeTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DeepSenoTheme.textSecondary)
                Spacer()
                regenerateButton
            }
            Text(i18n.t.briefingNoNarrativeSubtitle)
                .font(.system(size: 12))
                .foregroundStyle(DeepSenoTheme.textTertiary)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(DeepSenoTheme.bgSecondary.opacity(0.6))
        )
    }

    private func sectionHeaderWithCount(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            sectionHeader(title)
            Text(String(format: i18n.t.briefingItemCountFormat, count))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(DeepSenoTheme.textTertiary)
        }
    }

    // MARK: - Weekly Content

    private var weeklyContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let gen = viewModel.weeklySummary?.generatedAt,
                   let ago = RelativeTime.ago(from: gen, locale: i18n.lang) {
                    generatedAtRow(ago)
                }
                if let weekly = viewModel.weeklySummary {
                    // Try to render the structured payload; fall back to plain text.
                    if let json = weekly.summaryJson,
                       let structured = WeeklySummaryStructured.tryDecode(from: json) {
                        weeklyStructuredContent(structured)
                    } else {
                        sectionHeader(i18n.t.weeklySummary)
                        VStack(alignment: .leading, spacing: 8) {
                            if let json = weekly.summaryJson {
                                Text(json)
                                    .font(DeepSenoTheme.bodyFont)
                                    .foregroundStyle(DeepSenoTheme.textPrimary)
                            } else {
                                Text(i18n.t.noSummary)
                                    .font(DeepSenoTheme.bodyFont)
                                    .foregroundStyle(DeepSenoTheme.textSecondary)
                            }
                        }
                        .cardStyle()
                    }
                } else {
                    EmptyStateView(
                        icon: "calendar",
                        title: i18n.t.noWeeklySummary,
                        subtitle: i18n.t.noWeeklySummarySubtitle
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                }
            }
            .padding(16)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .refreshable {
            await loadIfConnected()
        }
    }

    // MARK: - Weekly Structured Content

    @ViewBuilder
    private func weeklyStructuredContent(_ s: WeeklySummaryStructured) -> some View {
        if let overview = s.overview, !overview.isEmpty {
            sectionHeader(i18n.t.weeklySummary)
            VStack(alignment: .leading, spacing: 8) {
                Text(overview)
                    .font(DeepSenoTheme.bodyFont)
                    .foregroundStyle(DeepSenoTheme.textPrimary)
            }
            .cardStyle()
        }

        if let themes = s.themes, !themes.isEmpty {
            sectionHeader(i18n.t.briefingWeeklyThemes)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(themes) { theme in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(theme.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(DeepSenoTheme.textPrimary)
                        if let summary = theme.summary, !summary.isEmpty {
                            Text(summary)
                                .font(DeepSenoTheme.bodyFont)
                                .foregroundStyle(DeepSenoTheme.textSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .cardStyle()
        }

        if let people = s.people, !people.isEmpty {
            sectionHeader(i18n.t.briefingWeeklyPeople)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(people) { person in
                    HStack(spacing: 6) {
                        Image(systemName: "person.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(DeepSenoTheme.accentBlue)
                        Text(person.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(DeepSenoTheme.textPrimary)
                        if let n = person.mentionCount {
                            Text("\(n)x")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(DeepSenoTheme.textTertiary)
                        }
                        Spacer()
                    }
                }
            }
            .cardStyle()
        }

        if let moments = s.keyMoments, !moments.isEmpty {
            sectionHeader(i18n.t.briefingWeeklyKeyMoments)
            // Vertical timeline: each moment shows a green dot + connector line
            // on the left; tapping pushes to source.
            VStack(spacing: 0) {
                ForEach(Array(moments.enumerated()), id: \.element.id) { idx, moment in
                    keyMomentTimelineRow(
                        moment: moment,
                        isFirst: idx == 0,
                        isLast: idx == moments.count - 1
                    )
                }
            }
            .cardStyle()
        }
    }

    @ViewBuilder
    private func keyMomentTimelineRow(
        moment: WeeklySummaryStructured.KeyMoment,
        isFirst: Bool,
        isLast: Bool
    ) -> some View {
        NavigationLink(value: BriefingSourceLink(
            recordingId: moment.recordingId,
            segmentId: moment.segmentId,
            recordingTitle: moment.recordingTitle,
            startTime: nil
        )) {
            HStack(alignment: .top, spacing: 12) {
                // Left rail: connector line + dot
                ZStack(alignment: .top) {
                    // Single vertical line spanning the row (clip ends for first/last)
                    Rectangle()
                        .fill(DeepSenoTheme.accentGreen.opacity(0.35))
                        .frame(width: 1.5)
                        .padding(.top, isFirst ? 14 : 0)
                        .padding(.bottom, isLast ? 0 : 0)
                        .frame(maxHeight: .infinity)

                    // Solid dot at moment row
                    Circle()
                        .fill(DeepSenoTheme.accentGreen)
                        .frame(width: 9, height: 9)
                        .padding(.top, 6)
                }
                .frame(width: 10)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if let date = moment.date {
                            Text(date)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(DeepSenoTheme.textTertiary)
                        }
                        if let title = moment.recordingTitle, !title.isEmpty {
                            Text(title)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(DeepSenoTheme.accentGreen)
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(DeepSenoTheme.textTertiary)
                    }
                    Text(moment.summary)
                        .font(DeepSenoTheme.bodyFont)
                        .foregroundStyle(DeepSenoTheme.textPrimary)
                        .multilineTextAlignment(.leading)
                }
                .padding(.bottom, isLast ? 0 : 14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func generatedAtRow(_ ago: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "sparkles")
                .font(.system(size: 10))
            Text(String(format: i18n.t.briefingGeneratedAtFormat, ago))
                .font(.system(.caption2, design: .monospaced))
            Spacer()
            regenerateButton
        }
        .foregroundStyle(DeepSenoTheme.textTertiary)
    }

    @ViewBuilder
    private var regenerateButton: some View {
        Button {
            guard let api = appState.apiClient else { return }
            Task { await viewModel.regenerate(apiClient: api) }
        } label: {
            HStack(spacing: 4) {
                if viewModel.isRegenerating {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(DeepSenoTheme.accentGreen)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(i18n.t.briefingRegenerate)
                    .font(.system(.caption2, design: .monospaced))
            }
            .foregroundStyle(viewModel.isRegenerating ? DeepSenoTheme.textTertiary : DeepSenoTheme.accentGreen)
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isRegenerating)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(.caption, design: .monospaced))
            .fontWeight(.semibold)
            .foregroundStyle(DeepSenoTheme.textSecondary)
            .tracking(1)
    }

    private func loadIfConnected() async {
        if let api = appState.apiClient {
            await viewModel.loadData(apiClient: api)
        }
    }
}
