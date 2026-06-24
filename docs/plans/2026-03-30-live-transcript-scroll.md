# Live Transcript Scrollable Preview — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the 4-line truncated transcript preview with a scrollable chat-bubble panel showing timestamped segments.

**Architecture:** Modify LiveTranscriber to output `[TranscriptSegment]` instead of a single `String`. Each SFSpeechRecognizer recognition round becomes one segment with a timestamp. CaptureView splits into top (compact controls) and bottom (scrollable bubble panel).

**Tech Stack:** SwiftUI, Speech framework (SFSpeechRecognizer), ScrollViewReader

---

### Task 1: Add TranscriptSegment model and refactor LiveTranscriber

**Files:**
- Modify: `DeepSeno/Services/LiveTranscriber.swift`

**Step 1: Add TranscriptSegment struct and update TranscriberResults**

Replace the entire `LiveTranscriber.swift` with:

```swift
import Foundation
import Speech

/// A single recognized speech segment with timestamp.
struct TranscriptSegment: Identifiable {
    let id = UUID()
    var text: String
    let timestamp: TimeInterval  // seconds into the recording
    var isFinal: Bool
}

/// Thread-safe box for recognition results.
private final class TranscriberResults: @unchecked Sendable {
    private let lock = NSLock()
    private var _latestText: String = ""
    private var _needsRestart = false

    var latestText: String {
        get { lock.lock(); defer { lock.unlock() }; return _latestText }
        set { lock.lock(); _latestText = newValue; lock.unlock() }
    }

    var needsRestart: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _needsRestart }
        set { lock.lock(); _needsRestart = newValue; lock.unlock() }
    }

    func reset() {
        lock.lock()
        _latestText = ""
        _needsRestart = false
        lock.unlock()
    }
}

/// On-device speech recognition. Receives audio buffers from AudioRecorder.
@Observable
class LiveTranscriber: NSObject {
    var segments: [TranscriptSegment] = []
    var isActive = false

    /// Backward-compat: joined text of all segments
    var text: String {
        segments.map(\.text).joined(separator: " ")
    }

    private var recognitionTask: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private let results = TranscriberResults()
    private var shouldBeActive = false
    private var pollTimer: Timer?
    private weak var recorder: AudioRecorder?

    func start(recorder: AudioRecorder) {
        #if targetEnvironment(simulator)
        return
        #else
        self.recorder = recorder
        shouldBeActive = true
        segments = []
        results.reset()

        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .authorized {
            doStart()
        } else if status == .notDetermined {
            let resultsRef = results
            SFSpeechRecognizer.requestAuthorization { newStatus in
                if newStatus == .authorized {
                    resultsRef.needsRestart = true
                }
            }
            startPolling()
        }
        #endif
    }

    func stop() {
        shouldBeActive = false
        pollTimer?.invalidate()
        pollTimer = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        request?.endAudio()
        request = nil
        recorder?.setOnAudioBuffer(nil)
        recorder = nil
        isActive = false
    }

    // MARK: - Private

    private func doStart() {
        guard shouldBeActive else { return }

        let prefersChinese = Locale.preferredLanguages.contains { $0.hasPrefix("zh") }
        let locale = Locale(identifier: prefersChinese ? "zh-Hans" : "en-US")
        let recognizer = SFSpeechRecognizer(locale: locale)
        guard let recognizer, recognizer.isAvailable else { return }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true
        if #available(iOS 16, *) {
            req.addsPunctuation = true
        }
        self.request = req

        // Create a new segment for this recognition round
        let segmentTimestamp = recorder?.duration ?? 0
        segments.append(TranscriptSegment(
            text: "",
            timestamp: segmentTimestamp,
            isFinal: false
        ))

        let resultsRef = results
        recognitionTask = recognizer.recognitionTask(with: req) { result, error in
            if let result {
                resultsRef.latestText = result.bestTranscription.formattedString
            }
            if error != nil || (result?.isFinal ?? false) {
                resultsRef.needsRestart = true
            }
        }

        let currentReq = req
        recorder?.setOnAudioBuffer { buffer in
            currentReq.append(buffer)
        }

        isActive = true
        startPolling()
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.shouldBeActive else { return }

            // Update current (last) segment text
            let newText = self.results.latestText
            if !newText.isEmpty, let lastIndex = self.segments.indices.last {
                if self.segments[lastIndex].text != newText {
                    self.segments[lastIndex].text = newText
                }
            }

            if self.results.needsRestart {
                self.results.needsRestart = false
                // Mark current segment as final
                if let lastIndex = self.segments.indices.last {
                    self.segments[lastIndex].isFinal = true
                }
                // Remove empty segments
                self.segments.removeAll { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                self.results.reset()
                self.recognitionTask?.cancel()
                self.recognitionTask = nil
                self.request?.endAudio()
                self.request = nil
                self.doStart()
            }
        }
    }
}
```

Key changes from original:
- Added `TranscriptSegment` struct
- `text: String` → `segments: [TranscriptSegment]` (with `text` as computed backward-compat)
- `doStart()` creates a new segment each round with `timestamp = recorder.duration`
- Poll timer updates last segment's text, marks final on restart
- Empty segments removed on restart

**Step 2: Build to verify**

Run: `xcodebuild build -scheme DeepSeno -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet 2>&1 | grep error:`
Expected: No errors (text computed property keeps existing references working)

**Step 3: Commit**

```
git add DeepSeno/Services/LiveTranscriber.swift
git commit -m "feat: LiveTranscriber outputs timestamped segments instead of plain string"
```

---

### Task 2: Replace liveTranscriptCard with scrollable bubble panel

**Files:**
- Modify: `DeepSeno/Views/Capture/CaptureView.swift`

**Step 1: Replace the liveTranscriptCard**

In CaptureView.swift, replace the `liveTranscriptCard` computed property (lines 278-298) with a scrollable bubble panel:

```swift
private var liveTranscriptPanel: some View {
    ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(viewModel.transcriber.segments) { segment in
                    transcriptBubble(segment: segment)
                        .id(segment.id)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .onChange(of: viewModel.transcriber.segments.count) { _, _ in
            if let last = viewModel.transcriber.segments.last {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
        // Also scroll on partial updates to keep latest text visible
        .onChange(of: viewModel.transcriber.segments.last?.text) { _, _ in
            if let last = viewModel.transcriber.segments.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}

private func transcriptBubble(segment: TranscriptSegment) -> some View {
    HStack(alignment: .top, spacing: 10) {
        // Timestamp
        Text(formatTimestamp(segment.timestamp))
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(DeepSenoTheme.textTertiary)
            .frame(width: 40, alignment: .trailing)

        // Bubble
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(segment.text)
                    .font(.system(size: 14))
                    .foregroundStyle(DeepSenoTheme.textSecondary)

                if !segment.isFinal {
                    // Blinking cursor
                    Text("▎")
                        .font(.system(size: 14))
                        .foregroundStyle(DeepSenoTheme.accentGreen)
                        .opacity(segment.isFinal ? 0 : 1)
                        .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: segment.isFinal)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DeepSenoTheme.bgTertiary.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(DeepSenoTheme.glassBorder, lineWidth: 1)
        )
    }
}

private func formatTimestamp(_ seconds: TimeInterval) -> String {
    let total = Int(seconds)
    let m = total / 60
    let s = total % 60
    return String(format: "%d:%02d", m, s)
}
```

**Step 2: Restructure body to split top controls / bottom panel**

Replace the body's VStack layout. The key change: when recording with active transcriber, the "Recording stage" area compacts and a transcript panel fills the bottom half.

Find this section in body (lines 34-96, the recording stage between Spacer and Spacer):

```swift
                Spacer()

                // -- Recording stage (central area) --
                VStack(spacing: 16) {
                    // ... waveform, timer, bookmarks, pause, live transcript, bookmark feedback
                }
                .animation(...)

                Spacer()
```

Replace with:

```swift
                if viewModel.transcriber.isActive && !viewModel.transcriber.segments.isEmpty {
                    // Compact controls when transcript is showing
                    Spacer().frame(height: 8)

                    VStack(spacing: 8) {
                        if viewModel.recorder.isRecording {
                            AudioWaveformView(level: viewModel.recorder.audioLevel, isPaused: viewModel.recorder.isPaused)
                                .frame(height: 40)
                                .padding(.horizontal, 20)
                        }

                        Text(viewModel.recorder.formattedDuration)
                            .font(.system(size: 28, weight: .light, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(DeepSenoTheme.textPrimary)

                        if !viewModel.recorder.bookmarks.isEmpty {
                            HStack(spacing: 5) {
                                Image(systemName: "bookmark.fill")
                                    .font(.system(size: 10))
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
                    .animation(.easeInOut(duration: 0.25), value: viewModel.recorder.isRecording)

                    // Transcript panel fills remaining space
                    liveTranscriptPanel
                        .transition(.move(edge: .bottom).combined(with: .opacity))

                } else {
                    // Original centered layout when no transcript
                    Spacer()

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
                    .animation(.easeInOut(duration: 0.25), value: viewModel.recorder.isRecording)

                    Spacer()
                }
```

Also remove the old `liveTranscriptCard` reference from the recording stage area (line 80-82 in original).

**Step 3: Delete old liveTranscriptCard**

Remove the old `liveTranscriptCard` computed property entirely (lines 278-298).

**Step 4: Build and verify**

Run: `xcodebuild build -scheme DeepSeno -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet 2>&1 | grep error:`
Expected: No errors

**Step 5: Commit**

```
git add DeepSeno/Views/Capture/CaptureView.swift
git commit -m "feat: scrollable chat-bubble transcript panel with timestamps"
```

---

### Task 3: Build and package

**Step 1: Full build verification**

```bash
cd /Users/mac/workspace/deepseno-ios
xcodebuild build -scheme DeepSeno -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet
```

**Step 2: Archive and export IPA**

```bash
xcodebuild -scheme DeepSeno -destination 'generic/platform=iOS' -archivePath /tmp/DeepSeno.xcarchive archive -quiet
xcodebuild -exportArchive -archivePath /tmp/DeepSeno.xcarchive -exportOptionsPlist /tmp/DevExportOptions.plist -exportPath /tmp/DeepSenoExport
cp /tmp/DeepSenoExport/DeepSeno.ipa build/DeepSeno-v1.5.1.ipa
```

**Step 3: Commit all**

```
git add -A
git commit -m "feat: live transcript scrollable bubble panel with timestamps"
```
