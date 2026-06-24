import SwiftUI
import AVFoundation

@Observable
class CaptureViewModel: @unchecked Sendable {
    var showTextMemo = false
    var memoText = ""
    var showFilePicker = false
    var errorMessage: String?
    var permissionDeniedKind: PermissionDeniedKind?
    var bookmarkFeedback = false
    var toastMessage: String?

    let recorder = AudioRecorder()
    let streamer = AudioStreamer()
    let transcriber = LiveTranscriber()

    /// Retained for the duration of recording + in-flight corrections. Replaced
    /// on each new recording, releasing the previous instance after its Tasks finish.
    var corrector: TranscriptCorrector?

    private var isStartingRecording = false

    enum PermissionDeniedKind {
        case microphone
    }

    func toggleRecording(queue: CaptureQueue, appState: AppState, savedLabel: String) {
        let webSocket = appState.webSocket
        if recorder.isRecording {
            let finalDuration = recorder.formattedDuration
            let writeFailed = recorder.didWriteFail

            // Stop everything
            transcriber.stop()
            transcriber.onSegmentFinalized = nil
            // `corrector` deliberately retained — its in-flight SSE tasks need to keep
            // running so the saved transcript view reflects the last corrections. It will
            // be replaced (and the previous instance released) on the next recording.
            streamer.stop()
            appState.activeStreamer = nil

            if let url = recorder.stopRecording() {
                Haptics.medium()
                if writeFailed {
                    errorMessage = "录音过程中写入失败，文件可能不完整"
                    Haptics.warning()
                    return
                }
                let fileName = url.lastPathComponent
                let bookmarksJSON: String? = recorder.bookmarks.isEmpty ? nil : {
                    let ms = recorder.bookmarks.map { Int($0 * 1000) }
                    return (try? JSONSerialization.data(withJSONObject: ms))
                        .flatMap { String(data: $0, encoding: .utf8) }
                }()
                queue.add(
                    type: "audio",
                    localPath: url.path,
                    fileName: fileName,
                    bookmarks: bookmarksJSON
                )

                // Show toast
                showToast("\(savedLabel) · \(finalDuration)")
            }
        } else {
            // Guard against rapid double-taps while permission/start is in flight
            guard !isStartingRecording else { return }
            isStartingRecording = true
            errorMessage = nil
            permissionDeniedKind = nil
            // Pin to @MainActor: AVAudioEngine.start() and the polling Timer
            // inside LiveTranscriber both need a runloop. Since this ViewModel
            // is no longer @MainActor (per CLAUDE.md), an unmarked Task would
            // resume on a background executor after the permission await and
            // recording would start with no buffers flowing.
            Task { @MainActor in
                defer { isStartingRecording = false }
                let granted = await AVAudioApplication.requestRecordPermission()
                guard granted else {
                    permissionDeniedKind = .microphone
                    errorMessage = "需要麦克风权限才能录音"
                    return
                }
                // Race-safety: another path may have started recording while we were awaiting
                guard !recorder.isRecording else { return }
                do {
                    try recorder.startRecording()
                    Haptics.medium()
                    // Start live transcription (uses recorder's engine for audio)
                    transcriber.start(recorder: recorder)
                    // Live-correction setup — only if the desktop is paired AND the user
                    // hasn't turned the toggle off. Closure hops to MainActor because
                    // TranscriptCorrector.enqueue is @MainActor.
                    let correctionOn = UserDefaults.standard.object(
                        forKey: TranscriptCorrector.correctionEnabledKey
                    ) as? Bool ?? true
                    if correctionOn,
                       webSocket.isConnected,
                       let host = appState.connectionHost,
                       let port = appState.connectionPort,
                       let token = appState.connectionToken {
                        let cor = TranscriptCorrector(
                            host: host, port: port, token: token,
                            secure: appState.connectionSecure,
                            fingerprint: appState.connectionFingerprint
                        )
                        cor.transcriber = transcriber
                        self.corrector = cor
                        transcriber.onSegmentFinalized = { [weak cor] id, locale in
                            Task { @MainActor in
                                cor?.enqueue(segmentId: id, locale: locale)
                            }
                        }
                    } else {
                        self.corrector = nil
                        transcriber.onSegmentFinalized = nil
                    }
                    // Start desktop streaming if connected
                    if webSocket.isConnected {
                        streamer.start(webSocket: webSocket)
                        appState.activeStreamer = streamer
                    }
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    func togglePause() {
        if recorder.isPaused {
            recorder.resumeRecording()
        } else {
            recorder.pauseRecording()
        }
    }

    func addBookmark() {
        recorder.addBookmark()
        Haptics.light()
        bookmarkFeedback = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            bookmarkFeedback = false
        }
    }

    func submitMemo(queue: CaptureQueue) {
        let text = memoText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        queue.add(
            type: "text",
            localPath: "",
            fileName: "memo-\(Int(Date().timeIntervalSince1970))",
            textContent: text
        )
        memoText = ""
        showTextMemo = false
    }

    private func showToast(_ message: String) {
        toastMessage = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if toastMessage == message {
                toastMessage = nil
            }
        }
    }
}
