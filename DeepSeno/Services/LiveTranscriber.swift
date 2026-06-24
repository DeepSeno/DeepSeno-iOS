import Foundation
import Speech

enum CorrectionState: Equatable {
    case none        // not eligible / disabled / desktop offline
    case pending     // queued, request not yet started
    case streaming   // SSE chunks arriving
    case done        // corrected text final
    case failed      // give up silently, fall back to raw text
}

/// A single recognized speech segment with timestamp.
struct TranscriptSegment: Identifiable {
    let id = UUID()
    var text: String                          // raw ASR text
    let timestamp: TimeInterval               // start seconds into the recording
    var endTimestamp: TimeInterval            // end seconds (updated as speech continues)
    var isFinal: Bool

    var correctedText: String? = nil          // nil until correction starts
    var correctionState: CorrectionState = .none

    /// The text to display: the corrected text only when it has visible
    /// (non-whitespace) content, otherwise the raw ASR text. This guards
    /// against an "optimization" that returns empty/whitespace silently
    /// wiping out good raw text — never let a blank correction win.
    var displayText: String {
        if let corrected = correctedText,
           !corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return corrected
        }
        return text
    }
}

/// Thread-safe box for a single recognition task's results.
private final class SegmentResults: @unchecked Sendable {
    private let lock = NSLock()
    private var _latestText: String = ""

    var latestText: String {
        get { lock.lock(); defer { lock.unlock() }; return _latestText }
        set { lock.lock(); _latestText = newValue; lock.unlock() }
    }

    func reset() {
        lock.lock()
        _latestText = ""
        lock.unlock()
    }
}

/// One language lane: a recognizer + its in-flight request + task + result buffer.
/// LiveTranscriber owns 1 lane for single-language modes and 2 lanes for
/// "multilingual" mode (zh-Hans + en-US running in parallel).
private final class RecognitionLane {
    let locale: String
    let recognizer: SFSpeechRecognizer?
    let results = SegmentResults()
    var request: SFSpeechAudioBufferRecognitionRequest?
    var task: SFSpeechRecognitionTask?

    init?(localeIdentifier: String) {
        self.locale = localeIdentifier
        let rec = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
        guard let rec, rec.isAvailable else { return nil }
        self.recognizer = rec
    }

    /// Spin up a new partial-results task. Old one (if any) is torn down first.
    func startTask() {
        endTask()
        results.reset()
        guard let recognizer else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true
        if #available(iOS 16, *) { req.addsPunctuation = true }
        self.request = req
        let resultsRef = results
        task = recognizer.recognitionTask(with: req) { result, _ in
            if let result {
                resultsRef.latestText = result.bestTranscription.formattedString
            }
        }
    }

    /// `finish()` (not `cancel()`) so the recognizer can deliver any final result
    /// for audio that's already buffered.
    func endTask() {
        request?.endAudio()
        task?.finish()
        task = nil
        request = nil
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
    }
}

/// On-device speech recognition. Receives audio buffers from AudioRecorder.
///
/// Architecture: VAD (voice activity detection) via audio level drives the lifecycle.
/// Each speech segment gets its own `RecognitionLane`(s); for multilingual mode we
/// run two lanes in parallel and pick the longer transcript as the segment text.
@Observable
class LiveTranscriber: NSObject {
    var segments: [TranscriptSegment] = []
    var isActive = false

    /// Backward-compat: joined text of all segments
    var text: String {
        segments.map(\.text).joined(separator: " ")
    }

    private var lanes: [RecognitionLane] = []
    private var shouldBeActive = false
    private var pollTimer: Timer?
    private weak var recorder: AudioRecorder?

    /// Called whenever a segment is finalized (isFinal flips to true).
    /// Set by CaptureViewModel after start(). Tuple is (segmentId, locale).
    var onSegmentFinalized: ((UUID, String) -> Void)?

    /// Locale identifier captured at start(). For multilingual mode this is
    /// "multilingual" even though two lanes run in parallel.
    private(set) var activeLocale: String = "en-US"

    // VAD state
    private var isSpeaking = false
    private var silenceStart: TimeInterval = 0
    private let silenceThreshold: Float = 0.05    // audio level below this = silence
    private let silenceDuration: TimeInterval = 0.8 // seconds of silence to split

    // Controls whether audio buffers are forwarded to the recognizer.
    // Accessed from audio thread — volatile bool is fine.
    private var isForwardingAudio = false

    /// Start live transcription. Call after recorder.startRecording().
    func start(recorder: AudioRecorder) {
        #if targetEnvironment(simulator)
        return
        #else
        self.recorder = recorder
        shouldBeActive = true
        segments = []
        isSpeaking = false
        silenceStart = 0
        isForwardingAudio = false

        // Resolve which language lanes to spin up. The picker stores either a
        // single locale id ("zh-Hans" / "en-US"), the literal "multilingual" for
        // parallel recognition, or nothing (auto = pick by system language).
        // SettingsView writes "" for auto, never removes the key. Treat empty
        // and missing identically.
        let override = UserDefaults.standard.string(forKey: "transcription_locale") ?? ""
        let (localeIds, resolvedLocale): ([String], String) = {
            switch override {
            case "zh-Hans": return (["zh-Hans"], "zh-Hans")
            case "en-US":   return (["en-US"], "en-US")
            case "multilingual": return (["zh-Hans", "en-US"], "multilingual")
            default:
                let id = Locale.preferredLanguages.contains { $0.hasPrefix("zh") } ? "zh-Hans" : "en-US"
                return ([id], id)
            }
        }()
        self.activeLocale = resolvedLocale
        lanes = localeIds.compactMap { RecognitionLane(localeIdentifier: $0) }

        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { _ in }
        }

        // Audio forwarding — fan out the same buffer to every lane.
        recorder.setOnAudioBuffer { [weak self] buffer in
            guard let self, self.isForwardingAudio else { return }
            for lane in self.lanes { lane.append(buffer) }
        }

        isActive = true
        startPolling()
        #endif
    }

    func stop() {
        shouldBeActive = false
        isForwardingAudio = false
        pollTimer?.invalidate()
        pollTimer = nil

        // Commit the best-known text for the active segment before tearing the
        // lanes down (see endSegment for the rationale).
        let merged = lanes.map(\.results.latestText).max(by: { $0.count < $1.count }) ?? ""
        for lane in lanes { lane.endTask() }
        recorder?.setOnAudioBuffer(nil)
        recorder = nil
        lanes = []
        isActive = false

        if let lastIndex = segments.indices.last, !segments[lastIndex].isFinal {
            if !merged.isEmpty { segments[lastIndex].text = merged }
            segments[lastIndex].isFinal = true
            if !segments[lastIndex].text.isEmpty {
                let finalizedId = segments[lastIndex].id
                onSegmentFinalized?(finalizedId, activeLocale)
            }
        }
        sweepBlankFinalSegments()
    }

    // MARK: - Polling (VAD + text update)

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.shouldBeActive else { return }

            let now = self.recorder?.duration ?? 0
            let level = self.recorder?.audioLevel ?? 0

            // --- VAD: detect speech / silence transitions ---
            if level >= self.silenceThreshold {
                if !self.isSpeaking {
                    self.isSpeaking = true
                    self.beginSegment(at: now)
                }
                self.silenceStart = now
                if let last = self.segments.indices.last, !self.segments[last].isFinal {
                    self.segments[last].endTimestamp = now
                }
            } else if self.isSpeaking {
                let silentFor = now - self.silenceStart
                if silentFor >= self.silenceDuration {
                    self.isSpeaking = false
                    self.endSegment()
                }
            }

            // --- Update current segment text: pick the longer of all lanes ---
            // For single-language mode there's only one lane. For multilingual
            // the lane whose recognizer recognized more usually wins, which is
            // the right behavior when the speaker mostly uses one language with
            // occasional words from the other.
            let merged = self.lanes
                .map(\.results.latestText)
                .max(by: { $0.count < $1.count }) ?? ""
            if let last = self.segments.lastIndex(where: { !$0.isFinal }) {
                if !merged.isEmpty, self.segments[last].text != merged {
                    self.segments[last].text = merged
                }
            }
        }
    }

    // MARK: - Segment lifecycle

    private func beginSegment(at timestamp: TimeInterval) {
        segments.append(TranscriptSegment(
            text: "",
            timestamp: timestamp,
            endTimestamp: timestamp,
            isFinal: false
        ))
        for lane in lanes { lane.startTask() }
        isForwardingAudio = true
    }

    private func endSegment() {
        isForwardingAudio = false

        if let last = segments.indices.last, !segments[last].isFinal {
            // Commit the best-known recognized text BEFORE finalizing. The poll
            // loop only writes to the active (non-final) segment, so without this
            // the segment freezes at whatever partial happened to be there when
            // VAD cut on silence — and the recognizer's final result (delivered
            // after finish()) would be lost to the lane instead of this segment.
            let merged = lanes.map(\.results.latestText).max(by: { $0.count < $1.count }) ?? ""
            if !merged.isEmpty { segments[last].text = merged }
            segments[last].endTimestamp = silenceStart
            segments[last].isFinal = true
            if !segments[last].text.isEmpty {
                let finalizedId = segments[last].id
                onSegmentFinalized?(finalizedId, activeLocale)
            }
        }

        for lane in lanes { lane.endTask() }
        sweepBlankFinalSegments()
    }

    /// Remove finalized segments that captured no speech (a VAD noise blip). A
    /// finalized segment can never gain text later (the poll loop only writes to
    /// the active one), so a blank final is permanently empty. Deciding visibility
    /// here — once, at the data layer — keeps it STABLE. The previous approach
    /// (a per-render `filter` in the view, derived from async-mutated text) could
    /// transiently drop a segment the user was reading, producing an intermittent
    /// "it vanished" flicker. The active (non-final) segment is never swept, so
    /// its live cursor stays visible.
    private func sweepBlankFinalSegments() {
        segments.removeAll {
            $0.isFinal && $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}
