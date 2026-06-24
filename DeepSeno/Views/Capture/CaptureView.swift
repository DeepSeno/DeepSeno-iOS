import SwiftUI
import UniformTypeIdentifiers

struct CaptureView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.i18n) private var i18n
    private var viewModel: CaptureViewModel { appState.captureVM }
    @State private var showMultiCamera = false
    @State private var showImagePicker = false
    @State private var showVideoCapture = false
    @State private var showVideoPicker = false

    private var hasTranscript: Bool {
        viewModel.transcriber.isActive && !viewModel.transcriber.segments.isEmpty
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        ZStack {
            // Background
            DeepSenoTheme.bgPrimary.ignoresSafeArea()

            VStack(spacing: 0) {
                // -- Top bar --
                HStack {
                    ConnectionBadge(
                        isConnected: appState.isConnected,
                        host: appState.connectionHost,
                        transportMode: appState.relayTransportMode,
                        reconnectStatus: appState.reconnectCoordinator.status
                    )
                    Spacer()
                    if viewModel.transcriber.isActive {
                        transcriberBadge
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                if hasTranscript {
                    // ===== COMPACT MODE: controls + scrollable transcript =====
                    Spacer().frame(height: 8)

                    compactRecordingControls

                    // Transcript panel fills remaining space
                    liveTranscriptPanel
                        .transition(.move(edge: .bottom).combined(with: .opacity))

                } else {
                    // ===== NORMAL MODE: centered large controls =====
                    Spacer()
                    normalRecordingStage
                    Spacer()
                }

                // -- Control buttons --
                HStack(spacing: 28) {
                    if viewModel.recorder.isRecording {
                        Button {
                            viewModel.togglePause()
                        } label: {
                            Image(systemName: viewModel.recorder.isPaused ? "play.fill" : "pause.fill")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(DeepSenoTheme.textPrimary)
                                .frame(width: 48, height: 48)
                                .background(DeepSenoTheme.bgTertiary.opacity(0.8))
                                .clipShape(Circle())
                                .overlay(Circle().stroke(DeepSenoTheme.glassBorder, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .transition(.scale.combined(with: .opacity))
                    }

                    RecordButton(isRecording: viewModel.recorder.isRecording) {
                        viewModel.toggleRecording(
                            queue: appState.captureQueue,
                            appState: appState,
                            savedLabel: i18n.t.recordingSaved
                        )
                    }

                    if viewModel.recorder.isRecording {
                        Button {
                            viewModel.addBookmark()
                        } label: {
                            Image(systemName: "bookmark.fill")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(DeepSenoTheme.accentAmber)
                                .frame(width: 48, height: 48)
                                .background(DeepSenoTheme.bgTertiary.opacity(0.8))
                                .clipShape(Circle())
                                .overlay(Circle().stroke(DeepSenoTheme.glassBorder, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(i18n.t.a11yAddBookmark)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: viewModel.recorder.isRecording)
                .padding(.bottom, hasTranscript ? 12 : 36)

                // -- Action buttons --
                if !hasTranscript {
                    HStack(spacing: 48) {
                        Menu {
                            Button { showMultiCamera = true } label: {
                                Label(i18n.t.camera, systemImage: "camera")
                            }
                            Button { showImagePicker = true } label: {
                                Label(i18n.t.chooseImages, systemImage: "photo.on.rectangle")
                            }
                            Button { showVideoCapture = true } label: {
                                Label(i18n.t.recordVideo, systemImage: "video")
                            }
                            Button { showVideoPicker = true } label: {
                                Label(i18n.t.chooseVideo, systemImage: "film")
                            }
                        } label: {
                            ActionButtonLabel(icon: "plus", label: i18n.t.capture)
                        }
                        ActionButton(icon: "text.bubble.fill", label: i18n.t.memo) {
                            viewModel.showTextMemo = true
                        }
                        ActionButton(icon: "doc.badge.plus", label: i18n.t.importFile) {
                            viewModel.showFilePicker = true
                        }
                    }
                    .padding(.bottom, 16)
                }

                // -- Error message --
                if let error = viewModel.errorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 12))
                        Text(error)
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(DeepSenoTheme.accentRed)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(DeepSenoTheme.accentRed.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(DeepSenoTheme.accentRed.opacity(0.15), lineWidth: 1))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                }

                // -- Upload queue --
                if appState.captureQueue.pendingCount > 0 || appState.captureQueue.failedCount > 0 {
                    uploadQueueBar
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                }
            }

            // -- Toast overlay --
            if let toast = viewModel.toastMessage {
                VStack {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(DeepSenoTheme.accentGreen)
                        Text(toast)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(DeepSenoTheme.textPrimary)
                    }
                    .glassCard(cornerRadius: 20, padding: 0)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .padding(.top, 50)

                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: viewModel.toastMessage != nil)
            }
        }
        .sheet(isPresented: $viewModel.showTextMemo) {
            TextMemoSheet(viewModel: viewModel, queue: appState.captureQueue)
        }
        .fileImporter(
            isPresented: $viewModel.showFilePicker,
            allowedContentTypes: [
                .audio, .wav, .mp3, .mpeg4Audio,
                .movie, .mpeg4Movie, .quickTimeMovie,
                .pdf, .plainText,
                .image, .jpeg, .png, .heic
            ],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                guard url.startAccessingSecurityScopedResource() else { return }
                defer { url.stopAccessingSecurityScopedResource() }
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: tempURL)
                try? FileManager.default.copyItem(at: url, to: tempURL)
                appState.captureQueue.add(
                    type: "file",
                    localPath: tempURL.path,
                    fileName: url.lastPathComponent
                )
            }
        }
        .fullScreenCover(isPresented: $showMultiCamera) {
            MultiPhotoCaptureView { urls in handleMultiPhotos(urls) }
        }
        .sheet(isPresented: $showImagePicker) {
            MediaPickerView(mode: .images) { urls in handleMultiPhotos(urls) }
        }
        .fullScreenCover(isPresented: $showVideoCapture) {
            VideoCaptureView { videoURL in
                appState.captureQueue.add(type: "file", localPath: videoURL.path, fileName: videoURL.lastPathComponent)
            }
        }
        .sheet(isPresented: $showVideoPicker) {
            MediaPickerView(mode: .video) { urls in
                if let url = urls.first {
                    appState.captureQueue.add(type: "file", localPath: url.path, fileName: url.lastPathComponent)
                }
            }
        }
    }

    // MARK: - Recording Stage (Normal)

    private var normalRecordingStage: some View {
        VStack(spacing: 16) {
            if viewModel.recorder.isRecording {
                AudioWaveformView(level: viewModel.recorder.audioLevel, isPaused: viewModel.recorder.isPaused)
                    .frame(height: 80)
                    .padding(.horizontal, 20)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }

            Text(viewModel.recorder.formattedDuration)
                .font(DeepSenoTheme.timerFont)
                .monospacedDigit()
                .foregroundStyle(
                    viewModel.recorder.isRecording
                        ? DeepSenoTheme.textPrimary
                        : DeepSenoTheme.textSecondary.opacity(0.5)
                )
                .shadow(
                    color: viewModel.recorder.isRecording ? DeepSenoTheme.accentGreen.opacity(0.15) : .clear,
                    radius: 20
                )

            bookmarkAndPauseIndicators
        }
        .animation(.easeInOut(duration: 0.25), value: viewModel.recorder.isRecording)
    }

    // MARK: - Recording Controls (Compact — when transcript is showing)

    private var compactRecordingControls: some View {
        VStack(spacing: 6) {
            if viewModel.recorder.isRecording {
                AudioWaveformView(level: viewModel.recorder.audioLevel, isPaused: viewModel.recorder.isPaused)
                    .frame(height: 36)
                    .padding(.horizontal, 20)
            }

            Text(viewModel.recorder.formattedDuration)
                .font(.system(size: 28, weight: .light, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(DeepSenoTheme.textPrimary)

            bookmarkAndPauseIndicators
        }
        .animation(.easeInOut(duration: 0.25), value: viewModel.recorder.isRecording)
    }

    // MARK: - Shared indicators

    private var bookmarkAndPauseIndicators: some View {
        Group {
            if !viewModel.recorder.bookmarks.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "bookmark.fill").font(.system(size: 10))
                    Text("\(viewModel.recorder.bookmarks.count)")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                }
                .foregroundStyle(DeepSenoTheme.accentAmber)
            }

            if viewModel.recorder.isPaused {
                Text(i18n.t.paused)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(DeepSenoTheme.accentAmber)
                    .tracking(2)
            }

            if viewModel.bookmarkFeedback {
                HStack(spacing: 5) {
                    Image(systemName: "bookmark.fill").font(.system(size: 11))
                    Text(i18n.t.bookmarkAdded).font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(DeepSenoTheme.accentAmber)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
    }

    // MARK: - Live Transcript Panel

    private var liveTranscriptPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    // Render every segment unconditionally. Blank "noise" finals are
                    // already removed at the data layer (LiveTranscriber finalize),
                    // so a segment that's on screen with text stays on screen — its
                    // visibility no longer depends on a per-render content filter,
                    // which used to drop a row mid-read intermittently.
                    ForEach(viewModel.transcriber.segments) { segment in
                        transcriptBubble(segment: segment)
                            .id(segment.id)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            // Single onChange watching both segment-count and latest text.
            // Merged from two observers to avoid double rebuilds per transcription update.
            .onChange(of: TranscriptScrollKey(
                count: viewModel.transcriber.segments.count,
                lastText: viewModel.transcriber.segments.last?.text
            )) { _, _ in
                scrollToBottom(proxy: proxy)
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if let last = viewModel.transcriber.segments.last {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private func transcriptBubble(segment: TranscriptSegment) -> some View {
        // Same vocabulary as SourceDetailView: thin left accent bar, time on top,
        // text below — no boxed bubble, which felt out of place on the dark page.
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(segment.isFinal
                      ? DeepSenoTheme.accentGreen.opacity(0.5)
                      : DeepSenoTheme.accentGreen)
                .frame(width: 3)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(segment.isFinal
                         ? "\(formatTimestamp(segment.timestamp)) – \(formatTimestamp(segment.endTimestamp))"
                         : formatTimestamp(segment.timestamp))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(DeepSenoTheme.textTertiary)

                    // Drives the sparkle's cross-fade when state flips
                    // streaming→done. The pulsing dot self-animates onAppear,
                    // so it doesn't depend on this transaction.
                    correctionIndicator(for: segment.correctionState)
                        .animation(.easeInOut(duration: 0.25), value: segment.correctionState)
                }

                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(segment.displayText.isEmpty ? " " : segment.displayText)
                        .font(.system(size: 15))
                        .lineSpacing(3)
                        .foregroundStyle(DeepSenoTheme.textPrimary)
                        .animation(.easeInOut(duration: 0.2), value: segment.displayText)

                    if !segment.isFinal {
                        BlinkingCursor()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func correctionIndicator(for state: CorrectionState) -> some View {
        switch state {
        case .done:
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DeepSenoTheme.accentGreen)
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
        case .pending, .streaming:
            PulsingDot()
        case .none, .failed:
            EmptyView()
        }
    }

    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Sub-views

    private var transcriberBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(DeepSenoTheme.accentGreen)
                .frame(width: 6, height: 6)
            Text(i18n.t.liveTranscript)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DeepSenoTheme.accentGreen)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(DeepSenoTheme.accentGreen.opacity(0.1))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(DeepSenoTheme.accentGreen.opacity(0.2), lineWidth: 1))
    }

    private var uploadQueueBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.circle.fill")
                .foregroundStyle(DeepSenoTheme.accentGreen)
                .font(.system(size: 13))

            if appState.captureQueue.pendingCount > 0 {
                Text("\(appState.captureQueue.pendingCount) \(i18n.t.pending)")
                    .font(.system(size: 12))
                    .foregroundStyle(DeepSenoTheme.textSecondary)
            }

            if appState.captureQueue.failedCount > 0 {
                Text("\(appState.captureQueue.failedCount) \(i18n.t.failed)")
                    .font(.system(size: 12))
                    .foregroundStyle(DeepSenoTheme.accentRed)
            }

            Spacer()

            if appState.captureQueue.isProcessing {
                ProgressView()
                    .controlSize(.small)
                    .tint(DeepSenoTheme.textSecondary)
            }
        }
        .glassCard(cornerRadius: 10, padding: 10)
    }

    private func handleMultiPhotos(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if urls.count == 1 {
            appState.captureQueue.add(type: "photo", localPath: urls[0].path, fileName: urls[0].lastPathComponent)
        } else {
            let groupName = "group-\(Int(Date().timeIntervalSince1970))"
            let paths = urls.map(\.path)
            let fileNames = urls.enumerated().map { i, _ in String(format: "%02d.jpg", i + 1) }
            appState.captureQueue.addGroup(type: "photo", localPaths: paths, fileNames: fileNames, groupName: groupName)
        }
    }
}

// MARK: - BlinkingCursor

private struct TranscriptScrollKey: Equatable {
    let count: Int
    let lastText: String?
}

/// Self-animating pulse for in-flight correction. The parent's correctionState
/// rarely flips during a single segment's correction, so the pulse drives off
/// its own @State (same pattern as BlinkingCursor below).
private struct PulsingDot: View {
    @State private var on = false

    var body: some View {
        Circle()
            .fill(DeepSenoTheme.accentGreen)
            .frame(width: 5, height: 5)
            .opacity(on ? 1.0 : 0.4)
            .scaleEffect(on ? 1.0 : 0.7)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    on = true
                }
            }
    }
}

private struct BlinkingCursor: View {
    @State private var visible = true

    var body: some View {
        Text("▎")
            .font(.system(size: 14))
            .foregroundStyle(DeepSenoTheme.accentGreen)
            .opacity(visible ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                    visible = false
                }
            }
    }
}

// MARK: - AudioWaveformView

struct AudioWaveformView: View {
    let level: Float
    let isPaused: Bool

    @State private var levels: [Float] = Array(repeating: 0, count: 48)
    @State private var lastTick: Date = .distantPast

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.05)) { context in
            Canvas { ctx, size in
                let barCount = levels.count
                let totalBarWidth = size.width / CGFloat(barCount)
                let barWidth = totalBarWidth * 0.65
                let gap = totalBarWidth * 0.35
                let midY = size.height / 2

                for i in 0..<barCount {
                    let intensity = CGFloat(levels[i])
                    let barHeight = max(2, intensity * size.height * 0.85)
                    let x = CGFloat(i) * totalBarWidth + gap / 2
                    let rect = CGRect(
                        x: x,
                        y: midY - barHeight / 2,
                        width: barWidth,
                        height: barHeight
                    )

                    let baseColor = isPaused ? DeepSenoTheme.textTertiary : DeepSenoTheme.accentGreen
                    let alpha = 0.4 + Double(levels[i]) * 0.6
                    ctx.fill(
                        Path(roundedRect: rect, cornerRadius: barWidth / 2),
                        with: .color(baseColor.opacity(alpha))
                    )
                }
            }
            .onChange(of: context.date) { _, now in
                // Advance the bar window on every animation tick so the waveform
                // keeps scrolling even when level == 0 (silence shows as flat,
                // not a frozen frame).
                guard !isPaused else { return }
                // Throttle to ~20 Hz regardless of TimelineView frequency.
                if now.timeIntervalSince(lastTick) >= 0.05 {
                    lastTick = now
                    levels.removeFirst()
                    levels.append(level)
                }
            }
        }
    }
}

// MARK: - ActionButton

/// Visual shell shared by Button and Menu-backed action items. Extracted so
/// `Menu { … } label: { ActionButtonLabel(...) }` looks identical to a plain
/// ActionButton.
private struct ActionButtonLabel: View {
    let icon: String
    let label: String
    var disabled: Bool = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .frame(width: 46, height: 46)
                .background(DeepSenoTheme.bgTertiary.opacity(0.7))
                .clipShape(Circle())
                .overlay(Circle().stroke(DeepSenoTheme.glassBorder, lineWidth: 1))

            Text(label)
                .font(.system(size: 11))
        }
        .foregroundStyle(
            disabled ? DeepSenoTheme.textSecondary.opacity(0.3) : DeepSenoTheme.textSecondary
        )
    }
}

private struct ActionButton: View {
    let icon: String
    let label: String
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ActionButtonLabel(icon: icon, label: label, disabled: disabled)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}
