import SwiftUI
import AVKit

private enum DetailTab: String, CaseIterable {
    case summary, timeline, transcript, content, ocrText
}

struct SourceDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.i18n) private var i18n
    let recording: Recording
    /// When set, after segments load we switch to the transcript tab, scroll to
    /// this segment, and briefly highlight it. Used by Briefing items that jump
    /// to source.
    var focusSegmentId: Int? = nil

    @State private var segments: [Segment] = []
    @State private var meetingNotes: MeetingNotes?
    @State private var extractedItems: [ExtractedItem] = []
    @State private var imageCount: Int = 0
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedTab: DetailTab = .summary
    @State private var videoPlayer: AVPlayer?
    @State private var highlightedSegmentId: Int? = nil

    private var availableTabs: [DetailTab] {
        switch recording.mediaType {
        case "video":              return [.summary, .transcript]
        case "pdf", "docx", "text": return [.summary, .content]
        case "image":              return [.summary, .ocrText]
        default:                   return [.summary, .timeline, .transcript]
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Meta bar
            headerSection
                .padding(.horizontal, 16)
                .padding(.top, 8)

            // Video player
            if recording.mediaType == "video" {
                if let player = videoPlayer {
                    VideoPlayer(player: player)
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .onDisappear { player.pause() }
                } else if !isLoading {
                    HStack {
                        Image(systemName: "video.slash")
                            .font(.system(size: 20, weight: .light))
                            .foregroundStyle(DeepSenoTheme.textTertiary)
                        Text(i18n.t.noTranscript)
                            .font(.system(size: 13))
                            .foregroundStyle(DeepSenoTheme.textSecondary)
                    }
                    .frame(height: 120)
                    .frame(maxWidth: .infinity)
                    .background(DeepSenoTheme.bgSecondary.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
            }

            // Tab selector
            tabSelector
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            // Content
            if isLoading {
                Spacer()
                ProgressView()
                    .tint(DeepSenoTheme.accentGreen)
                    .scaleEffect(0.9)
                Spacer()
            } else if let error = errorMessage {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28, weight: .ultraLight))
                        .foregroundStyle(DeepSenoTheme.accentRed)
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(DeepSenoTheme.textSecondary)
                }
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            switch selectedTab {
                            case .summary: summaryTabContent
                            case .timeline: timelineTabContent
                            case .transcript: transcriptTabContent
                            case .content: contentTabContent
                            case .ocrText: ocrTextTabContent
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 20)
                    }
                    // When a focus segment becomes scrollable (segments loaded +
                    // we're on transcript tab), animate to it and flash highlight.
                    .onChange(of: focusedSegmentReady) { _, ready in
                        guard ready, let sid = focusSegmentId else { return }
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(120))
                            withAnimation(.easeInOut(duration: 0.35)) {
                                proxy.scrollTo(sid, anchor: .center)
                                highlightedSegmentId = sid
                            }
                            try? await Task.sleep(for: .seconds(2))
                            withAnimation(.easeOut(duration: 0.5)) {
                                highlightedSegmentId = nil
                            }
                        }
                    }
                }
            }
        }
        .background(DeepSenoTheme.bgPrimary)
        .navigationTitle(recording.fileName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await loadData() }
    }

    // MARK: - Tab Selector

    private var tabSelector: some View {
        HStack(spacing: 0) {
            ForEach(availableTabs, id: \.self) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedTab = tab
                    }
                } label: {
                    VStack(spacing: 6) {
                        Text(tabTitle(tab))
                            .font(.system(size: 13, weight: selectedTab == tab ? .semibold : .regular))
                            .foregroundStyle(
                                selectedTab == tab
                                    ? DeepSenoTheme.accentGreen
                                    : DeepSenoTheme.textTertiary
                            )

                        // Active underline
                        RoundedRectangle(cornerRadius: 1)
                            .fill(selectedTab == tab ? DeepSenoTheme.accentGreen : Color.clear)
                            .frame(height: 2)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func tabTitle(_ tab: DetailTab) -> String {
        switch tab {
        case .summary: i18n.t.summaryTab
        case .timeline: i18n.t.timelineTab
        case .transcript: i18n.t.transcriptTab
        case .content: i18n.t.contentTab
        case .ocrText: i18n.t.ocrTextTab
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 10) {
            StatusBadge(status: recording.status)

            if let duration = recording.formattedDuration {
                metaItem(icon: "clock", text: duration)
            }

            if let date = recording.recordedAt {
                metaItem(icon: "calendar", text: String(date.prefix(10)))
            }

            if let speakerCount = recording.speakerCount, speakerCount > 0 {
                metaItem(icon: "person.2.fill", text: "\(speakerCount)", color: DeepSenoTheme.accentBlue)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(DeepSenoTheme.bgSecondary.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(DeepSenoTheme.glassBorder, lineWidth: 0.5)
        )
    }

    private func metaItem(icon: String, text: String, color: Color = DeepSenoTheme.textSecondary) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 11))
        }
        .foregroundStyle(color)
    }

    // MARK: - Summary Tab

    @ViewBuilder
    private var summaryTabContent: some View {
        if recording.mediaType == "image" && imageCount > 0 {
            imageGallerySection
        }

        if let notes = meetingNotes {
            // Only show summary card if there's actual content
            if notes.title != nil || notes.discussionSummary != nil || (notes.keyTopics ?? []).isEmpty == false {
                summarySection(notes)
            }

            // Only show meeting-specific sections for audio/video
            if [nil, "audio", "video"].contains(recording.mediaType) {
                if let participants = notes.participants, !participants.isEmpty {
                    participantsSection(participants)
                }
                if let decisions = notes.decisions, !decisions.isEmpty {
                    decisionsSection(decisions)
                }
                if let actionItems = notes.actionItems, !actionItems.isEmpty {
                    actionItemsSection(actionItems)
                }
            }
        }

        if !extractedItems.isEmpty {
            extractedItemsSection
        }

        // Empty state when nothing to show
        if !hasSummaryContent {
            emptyStateView(i18n.t.noTranscript)
        }
    }

    private var hasSummaryContent: Bool {
        if recording.mediaType == "image" && imageCount > 0 { return true }
        if let notes = meetingNotes {
            if notes.title != nil || notes.discussionSummary != nil { return true }
            if let p = notes.participants, !p.isEmpty { return true }
            if let d = notes.decisions, !d.isEmpty { return true }
            if let a = notes.actionItems, !a.isEmpty { return true }
            if let t = notes.keyTopics, !t.isEmpty { return true }
        }
        if !extractedItems.isEmpty { return true }
        return false
    }

    // MARK: - Timeline Tab

    @ViewBuilder
    private var timelineTabContent: some View {
        if segments.isEmpty {
            emptyStateView(i18n.t.noTranscript)
        } else if isImageType {
            // Image OCR: plain text blocks, no timeline spine
            ForEach(segments) { segment in
                VStack(alignment: .leading, spacing: 6) {
                    Text(segment.displayText)
                        .font(.system(size: 14))
                        .foregroundStyle(DeepSenoTheme.textPrimary)
                        .lineSpacing(4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(cornerRadius: 10, padding: 14)
            }
        } else {
            let timelineBlocks = buildTimelineBlocks()
            ForEach(Array(timelineBlocks.enumerated()), id: \.offset) { index, block in
                timelineBlockView(block, isLast: index == timelineBlocks.count - 1)
            }
        }
    }

    // MARK: - Transcript Tab

    @ViewBuilder
    private var transcriptTabContent: some View {
        if segments.isEmpty {
            emptyStateView(i18n.t.noTranscript)
        } else if isImageType {
            // Image OCR: clean text blocks without speaker/time metadata
            ForEach(segments) { segment in
                Text(segment.displayText)
                    .font(.system(size: 14))
                    .foregroundStyle(DeepSenoTheme.textPrimary)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(segmentBackground(for: segment.id))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .id(segment.id)
            }
        } else {
            // Audio/video: verbatim text with a speaker-colored accent bar.
            // Timestamps intentionally live only in the Timeline tab — here the
            // focus is readable continuous text.
            ForEach(segments) { segment in
                HStack(alignment: .top, spacing: 0) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(speakerColor(for: segment.speakerId))
                        .frame(width: 3)
                        .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 4) {
                        if let speaker = segment.speakerName {
                            Text(speaker)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(speakerColor(for: segment.speakerId))
                        }

                        Text(segment.displayText)
                            .font(.system(size: 14))
                            .foregroundStyle(DeepSenoTheme.textPrimary)
                            .lineSpacing(3)
                    }
                    .padding(.leading, 10)
                    .padding(.vertical, 2)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(segmentBackground(for: segment.id))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .id(segment.id)
            }
        }
    }

    /// Highlight target segment for ~2s when navigated from a Briefing item,
    /// otherwise the standard subtle background.
    private func segmentBackground(for id: Int) -> Color {
        if highlightedSegmentId == id {
            return DeepSenoTheme.accentGreen.opacity(0.18)
        }
        return DeepSenoTheme.bgSecondary.opacity(0.45)
    }

    // MARK: - Content Tab (documents)

    @ViewBuilder
    private var contentTabContent: some View {
        if segments.isEmpty {
            emptyStateView(i18n.t.noTranscript)
        } else {
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                VStack(alignment: .leading, spacing: 6) {
                    Text("§\(index + 1)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(DeepSenoTheme.textTertiary)

                    Text(segment.displayText)
                        .font(.system(size: 14))
                        .foregroundStyle(DeepSenoTheme.textPrimary)
                        .lineSpacing(4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(DeepSenoTheme.bgSecondary.opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // MARK: - OCR Text Tab (images)

    @ViewBuilder
    private var ocrTextTabContent: some View {
        if segments.isEmpty {
            emptyStateView(i18n.t.noTranscript)
        } else {
            ForEach(segments) { segment in
                Text(segment.displayText)
                    .font(.system(size: 14))
                    .foregroundStyle(DeepSenoTheme.textPrimary)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(DeepSenoTheme.bgSecondary.opacity(0.45))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var isImageType: Bool {
        recording.mediaType == "image"
    }

    // MARK: - Summary Section

    private func summarySection(_ notes: MeetingNotes) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = notes.title {
                Text(title)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(DeepSenoTheme.textPrimary)
            }

            if let summary = notes.discussionSummary {
                HStack(spacing: 0) {
                    // Green quote border
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(DeepSenoTheme.accentGreen.opacity(0.6))
                        .frame(width: 3)
                    Text(summary)
                        .font(.system(size: 14))
                        .foregroundStyle(DeepSenoTheme.textSecondary)
                        .lineSpacing(3)
                        .padding(.leading, 10)
                }
            }

            if let topics = notes.keyTopics, !topics.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(topics, id: \.self) { topic in
                        Text(topic)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(DeepSenoTheme.accentGreen)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(DeepSenoTheme.accentGreen.opacity(0.1))
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(DeepSenoTheme.accentGreen.opacity(0.15), lineWidth: 0.5))
                    }
                }
            }
        }
        .glassCard(cornerRadius: 12, padding: 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Participants

    private func participantsSection(_ participants: [MeetingNotes.Participant]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(i18n.t.participants)
            ForEach(Array(participants.enumerated()), id: \.offset) { index, participant in
                HStack(spacing: 10) {
                    // Avatar
                    Circle()
                        .fill(Self.speakerColors[index % Self.speakerColors.count].opacity(0.2))
                        .frame(width: 30, height: 30)
                        .overlay(
                            Text(String(participant.name.prefix(1)).uppercased())
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(Self.speakerColors[index % Self.speakerColors.count])
                        )

                    Text(participant.name)
                        .font(.system(size: 14))
                        .foregroundStyle(DeepSenoTheme.textPrimary)

                    Spacer()

                    if let time = participant.speakingTime {
                        Text(formatSpeakingTime(time))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(DeepSenoTheme.textTertiary)
                    }
                }
            }
        }
        .glassCard(cornerRadius: 12, padding: 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Decisions

    private func decisionsSection(_ decisions: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(i18n.t.decisions)
            ForEach(decisions, id: \.self) { decision in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(DeepSenoTheme.accentAmber)
                        .frame(width: 18)
                    Text(decision)
                        .font(.system(size: 14))
                        .foregroundStyle(DeepSenoTheme.textPrimary)
                        .lineSpacing(2)
                }
            }
        }
        .glassCard(cornerRadius: 12, padding: 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Action Items

    private func actionItemsSection(_ items: [MeetingNotes.ActionItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(i18n.t.actionItems)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "circle")
                        .font(.system(size: 12))
                        .foregroundStyle(DeepSenoTheme.accentGreen)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.task)
                            .font(.system(size: 14))
                            .foregroundStyle(DeepSenoTheme.textPrimary)
                        HStack(spacing: 8) {
                            if let assignee = item.assignee {
                                Label(assignee, systemImage: "person.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(DeepSenoTheme.accentBlue)
                            }
                            if let dueDate = item.dueDate {
                                Label(dueDate, systemImage: "calendar")
                                    .font(.system(size: 10))
                                    .foregroundStyle(DeepSenoTheme.textTertiary)
                            }
                        }
                    }
                }
            }
        }
        .glassCard(cornerRadius: 12, padding: 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Extracted Items

    private var extractedItemsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(i18n.t.extractedItems)

            let grouped = Dictionary(grouping: extractedItems, by: \.type)
            ForEach(Array(grouped.keys.sorted()), id: \.self) { type in
                if let items = grouped[type] {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(type.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(colorForType(type))
                            .padding(.top, 4)

                        ForEach(items) { item in
                            HStack(alignment: .top, spacing: 8) {
                                Circle()
                                    .fill(colorForType(item.type))
                                    .frame(width: 5, height: 5)
                                    .padding(.top, 6)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.content)
                                        .font(.system(size: 13))
                                        .foregroundStyle(DeepSenoTheme.textPrimary)
                                    if let person = item.relatedPerson {
                                        Text(person)
                                            .font(.system(size: 11))
                                            .foregroundStyle(DeepSenoTheme.textTertiary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .glassCard(cornerRadius: 12, padding: 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Image Gallery

    private var imageGallerySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(imageCount > 1 ? "\(imageCount) \(i18n.t.photoCount)" : i18n.t.camera)

            if imageCount == 1 {
                if let api = appState.apiClient {
                    recordingImage(api: api)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(0..<imageCount, id: \.self) { index in
                            if let api = appState.apiClient {
                                // 200pt @3x = 600px → use 600 as the thumbnail cap
                                AuthenticatedImageView(apiClient: api, recordingId: recording.id, index: index, maxPixelSize: 600)
                                    .frame(width: 200, height: 200)
                            }
                        }
                    }
                }
            }
        }
        .glassCard(cornerRadius: 12, padding: 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func recordingImage(api: APIClient) -> some View {
        AuthenticatedImageView(apiClient: api, recordingId: recording.id)
    }

    // MARK: - Timeline Helpers

    private struct TimelineBlock {
        let startTime: String?
        let speakerName: String?
        let speakerId: Int?
        let text: String
    }

    /// A new timeline node starts on a speaker change, after a silence gap of at
    /// least this many seconds, or once a node has spanned this long. The last two
    /// rules matter for single-speaker recordings (the common iOS case): without
    /// them every segment shares one speakerId and collapses into a single block,
    /// leaving the Timeline tab with no visible time progression.
    private static let timelinePauseGap: Double = 4.0
    private static let timelineMaxSpan: Double = 30.0

    private func buildTimelineBlocks() -> [TimelineBlock] {
        guard !segments.isEmpty else { return [] }
        // Pre-build speaker lookup to avoid O(n) search per block
        var speakerNames: [Int: String] = [:]
        for seg in segments {
            if let id = seg.speakerId, let name = seg.speakerName, speakerNames[id] == nil {
                speakerNames[id] = name
            }
        }

        var blocks: [TimelineBlock] = []
        var currentSpeaker: Int?
        var currentTexts: [String] = []
        var blockStart: String?
        var blockStartValue: Double?
        var prevEnd: Double?
        var started = false

        func flush() {
            guard !currentTexts.isEmpty else { return }
            let name = currentSpeaker.flatMap { speakerNames[$0] }
            blocks.append(TimelineBlock(
                startTime: blockStart,
                speakerName: name,
                speakerId: currentSpeaker,
                text: currentTexts.joined(separator: " ")
            ))
        }

        for segment in segments {
            var gap: Double?
            if let prev = prevEnd, let start = segment.startTime { gap = start - prev }
            var span: Double?
            if let begin = blockStartValue, let start = segment.startTime { span = start - begin }

            let speakerChanged = started && segment.speakerId != currentSpeaker
            let longPause = (gap ?? 0) >= Self.timelinePauseGap
            let longSpan = (span ?? 0) >= Self.timelineMaxSpan

            if !started || speakerChanged || longPause || longSpan {
                flush()
                currentSpeaker = segment.speakerId
                currentTexts = [segment.displayText]
                blockStart = segment.formattedTime
                blockStartValue = segment.startTime
                started = true
            } else {
                currentTexts.append(segment.displayText)
            }
            prevEnd = segment.endTime ?? segment.startTime
        }
        flush()
        return blocks
    }

    private func timelineBlockView(_ block: TimelineBlock, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // Timeline spine
            VStack(spacing: 0) {
                Circle()
                    .fill(speakerColor(for: block.speakerId))
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(DeepSenoTheme.bgPrimary, lineWidth: 2))

                if !isLast {
                    Rectangle()
                        .fill(DeepSenoTheme.bgTertiary.opacity(0.6))
                        .frame(width: 1.5)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 8)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    if let time = block.startTime {
                        Text(time)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(DeepSenoTheme.textTertiary)
                    }
                    if let speaker = block.speakerName {
                        Text(speaker)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(speakerColor(for: block.speakerId))
                    }
                }

                Text(block.text)
                    .font(.system(size: 14))
                    .foregroundStyle(DeepSenoTheme.textPrimary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DeepSenoTheme.bgSecondary.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - Helpers

    private func emptyStateView(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "text.page")
                .font(.system(size: 36, weight: .ultraLight))
                .foregroundStyle(DeepSenoTheme.textTertiary)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(DeepSenoTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(50)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(1)
            .foregroundStyle(DeepSenoTheme.textTertiary)
    }

    private func formatSpeakingTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func colorForType(_ type: String) -> Color {
        switch type {
        case "todo": DeepSenoTheme.accentGreen
        case "meeting": DeepSenoTheme.accentBlue
        case "decision": DeepSenoTheme.accentAmber
        default: DeepSenoTheme.textSecondary
        }
    }

    private static let speakerColors: [Color] = [
        .blue, .green, .orange, .purple, .pink, .cyan, .mint, .indigo
    ]

    private func speakerColor(for speakerId: Int?) -> Color {
        guard let id = speakerId else { return DeepSenoTheme.accentGreen }
        return Self.speakerColors[id % Self.speakerColors.count]
    }

    private func loadData() async {
        guard let api = appState.apiClient else {
            errorMessage = i18n.t.notConnected
            isLoading = false
            return
        }

        async let segmentsTask: [Segment] = {
            do { return try await api.getSegments(recordingId: recording.id) }
            catch { return [] }
        }()
        async let itemsTask: [ExtractedItem] = {
            do { return try await api.getExtractedItems(recordingId: recording.id) }
            catch { return [] }
        }()
        async let notesTask: MeetingNotes? = {
            do { return try await api.getMeetingNotes(recordingId: recording.id) }
            catch { return nil }
        }()

        segments = await segmentsTask
        extractedItems = await itemsTask
        meetingNotes = await notesTask

        if recording.mediaType == "image" {
            let info = try? await api.getImageInfo(recordingId: recording.id)
            imageCount = info?.count ?? 0
        }

        // Initialize video player. On the public relay the media URL is a
        // self-signed https endpoint that AVPlayer's own TLS stack would reject,
        // so route byte-range loads through the cert-pinned resource loader.
        // On LAN (plain http) makePlayerItem returns a direct item unchanged.
        if recording.mediaType == "video", let url = await api.mediaURL(recordingId: recording.id) {
            let item = PinnedAsset.makePlayerItem(
                mediaURL: url,
                secure: appState.connectionSecure,
                fingerprint: appState.connectionFingerprint,
                fileName: recording.fileName
            )
            videoPlayer = AVPlayer(playerItem: item)
        }

        // Auto-select best tab: show transcript if summary has no real content
        if !segments.isEmpty && !hasSummaryContent {
            switch recording.mediaType {
            case "pdf", "docx", "text": selectedTab = .content
            case "image": selectedTab = .ocrText
            default: selectedTab = .transcript
            }
        }

        // If we were asked to focus a specific segment, force the transcript
        // tab so it's actually on screen for the scroll-to.
        if focusSegmentId != nil, segments.contains(where: { $0.id == focusSegmentId }) {
            selectedTab = .transcript
        }

        isLoading = false
    }

    /// True once the prerequisites for scrolling to the focus segment are met:
    /// segments are loaded, the focus id exists, and the transcript tab is showing.
    private var focusedSegmentReady: Bool {
        guard let sid = focusSegmentId else { return false }
        return selectedTab == .transcript && segments.contains(where: { $0.id == sid })
    }
}

// MARK: - Authenticated Image Loading

private struct AuthenticatedImageView: View {
    /// The APIClient owns the correct transport: on a public relay it's a pinned
    /// session (self-signed cert + SPKI pin), on LAN it's URLSession.shared.
    /// Fetching through it is what makes images load over the public relay —
    /// the previous version built its own URLSession.shared request, which the
    /// system rejected (-1202) on a secure connection.
    let apiClient: APIClient
    let recordingId: Int
    var index: Int = 0
    /// Max pixel size for downsampling. Default 1600 fits an iPhone Pro full-width retina image
    /// without holding a 12MP+ original in memory.
    var maxPixelSize: CGFloat = 1600
    @State private var image: UIImage?
    @State private var isLoading = true

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else if isLoading {
                RoundedRectangle(cornerRadius: 10)
                    .fill(DeepSenoTheme.bgTertiary.opacity(0.5))
                    .overlay(ProgressView().tint(DeepSenoTheme.accentGreen).scaleEffect(0.8))
                    .frame(height: 120)
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(DeepSenoTheme.bgTertiary.opacity(0.5))
                    .overlay(
                        Image(systemName: "photo")
                            .font(.system(size: 24, weight: .ultraLight))
                            .foregroundStyle(DeepSenoTheme.textTertiary)
                    )
                    .frame(height: 120)
            }
        }
        .task { await loadImage() }
    }

    private func loadImage() async {
        do {
            let data = try await apiClient.fetchImageData(recordingId: recordingId, index: index)
            let pixelSize = maxPixelSize
            // Downsample off the main actor; we only hop back to assign the result.
            let downsampled = await Task.detached(priority: .userInitiated) {
                ImageDownsampler.downsample(data: data, maxPixelSize: pixelSize)
            }.value
            image = downsampled
        } catch {
            print("[Image] load failed recording=\(recordingId) index=\(index): \(error)")
        }
        isLoading = false
    }
}

/// Decodes JPEG/PNG/HEIC at the smallest pixel size that still fits `maxPixelSize`
/// without ever materializing the full-resolution bitmap.
private enum ImageDownsampler {
    static func downsample(data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return UIImage(data: data)
        }
        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - FlowLayout

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        layout(in: proposal.width ?? 0, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let result = layout(in: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: .unspecified
            )
        }
    }

    private func layout(in width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxWidth = max(maxWidth, x)
        }
        return (CGSize(width: maxWidth, height: y + rowHeight), origins)
    }
}
