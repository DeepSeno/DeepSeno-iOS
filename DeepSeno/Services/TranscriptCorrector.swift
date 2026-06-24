import Foundation

/// Coordinates LLM correction of finalized transcript segments.
///
/// Lifecycle: created when recording starts, retained for the duration of
/// the recording, and `cancelAll()`-ed if the recording is discarded.
/// In-flight corrections at stop() are intentionally NOT cancelled — we
/// want the saved transcript view (post-stop) to reflect them.
@Observable
final class TranscriptCorrector: @unchecked Sendable {
    /// UserDefaults key for the on/off toggle. Read by both SettingsView's
    /// @AppStorage and the runtime guard in `enqueue`.
    static let correctionEnabledKey = "transcription_correction_enabled"

    weak var transcriber: LiveTranscriber?

    private let host: String
    private let port: Int
    private let token: String
    private let secure: Bool
    private let fingerprint: String?
    private let client = TranscriptCorrectionClient()

    /// Segments currently being corrected. Read on MainActor only.
    /// `Set<UUID>` rather than `[UUID: Task]` because we deliberately don't
    /// cancel in-flight Tasks — their own `[weak self]` closure capture keeps
    /// them alive until the SSE stream completes or the 30s timeout fires.
    @MainActor private var inFlight: Set<UUID> = []

    /// Per-segment partial accumulator. MainActor-isolated so chunk callbacks
    /// can append safely. Removed when the segment finalizes.
    @MainActor private var partials: [UUID: String] = [:]

    private let contextWindowSize = 3      // preceding finalized segments sent as LLM context
    private let minLength = 4              // skip "嗯/ok" filler — LLM over-corrects tiny fragments
    private let maxLengthMultiplier = 3    // reject corrections >3× raw — almost always hallucination

    init(host: String, port: Int, token: String, secure: Bool = false, fingerprint: String? = nil) {
        self.host = host
        self.port = port
        self.token = token
        self.secure = secure
        self.fingerprint = fingerprint
    }

    /// Called when a segment finalizes in LiveTranscriber. Decides eligibility
    /// (length, dedupe, user setting) and kicks off an async SSE correction.
    /// Idempotent — if the segment is already in flight or already done, no-op.
    @MainActor
    func enqueue(segmentId: UUID, locale: String) {
        guard let transcriber else { return }
        guard let idx = transcriber.segments.firstIndex(where: { $0.id == segmentId }) else { return }
        let segment = transcriber.segments[idx]

        // Already running, done, failed — no re-enqueue
        guard segment.correctionState == .none else { return }
        guard !inFlight.contains(segmentId) else { return }

        // Eligibility — length floor
        guard Self.shouldCorrect(text: segment.text, minLength: minLength) else { return }

        // User setting
        let enabled = UserDefaults.standard.object(
            forKey: Self.correctionEnabledKey
        ) as? Bool ?? true
        guard enabled else { return }

        // Build context: last N finalized segments BEFORE this one (use their
        // best-known text — corrected if available, raw otherwise).
        let context: [String] = transcriber.segments
            .prefix(idx)
            .filter { $0.isFinal }
            .suffix(contextWindowSize)
            .map { $0.displayText }

        inFlight.insert(segmentId)
        transcriber.segments[idx].correctionState = .pending
        partials[segmentId] = ""

        let rawText = segment.text
        let request = TranscriptCorrectionClient.Request(
            segmentId: segmentId.uuidString,
            text: rawText,
            locale: locale,
            context: context
        )

        Task { [weak self, client, host, port, token, secure, fingerprint] in
            guard let self else { return }
            do {
                try await client.stream(
                    host: host, port: port, token: token,
                    secure: secure, fingerprint: fingerprint, request: request
                ) { chunk in
                    // SSE callback is @Sendable. Bounce to MainActor to safely
                    // mutate `partials` and the segment's correctedText.
                    Task { @MainActor [weak self] in
                        self?.applyChunk(segmentId: segmentId, chunk: chunk)
                    }
                }
                await self.finalize(segmentId: segmentId, rawText: rawText, success: true)
            } catch {
                await self.finalize(segmentId: segmentId, rawText: rawText, success: false)
            }
        }
    }

    @MainActor
    private func applyChunk(segmentId: UUID, chunk: String) {
        guard let transcriber,
              let idx = transcriber.segments.firstIndex(where: { $0.id == segmentId }) else { return }
        let accumulated = (partials[segmentId] ?? "") + chunk
        partials[segmentId] = accumulated
        // Only override the displayed text once the partial has visible content.
        // SSE token streams often lead with whitespace/newlines; assigning that
        // would briefly blank out the raw text the user is already reading.
        if Self.isUsableCorrection(accumulated) {
            transcriber.segments[idx].correctedText = accumulated
        }
        transcriber.segments[idx].correctionState = .streaming
    }

    @MainActor
    private func finalize(segmentId: UUID, rawText: String, success: Bool) {
        let finalText = partials[segmentId] ?? ""
        partials.removeValue(forKey: segmentId)
        inFlight.remove(segmentId)

        guard let transcriber,
              let idx = transcriber.segments.firstIndex(where: { $0.id == segmentId }) else { return }

        if success, Self.isUsableCorrection(finalText),
           Self.isLengthSane(raw: rawText, corrected: finalText, multiplier: maxLengthMultiplier) {
            transcriber.segments[idx].correctedText = finalText
            transcriber.segments[idx].correctionState = .done
        } else {
            // Hallucination / network / empty / whitespace-only — fall back to
            // raw text silently. (nil → displayText returns the raw text.)
            transcriber.segments[idx].correctedText = nil
            transcriber.segments[idx].correctionState = .failed
        }
    }

    /// Decide whether a segment is a candidate for correction.
    /// Pure function — testable.
    static func shouldCorrect(text: String, minLength: Int) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= minLength
    }

    /// A correction is only usable if it has visible (non-whitespace) content.
    /// An empty / whitespace-only result must NOT replace the raw text —
    /// otherwise "optimization" silently wipes the segment to a blank line.
    /// Pure function — testable.
    static func isUsableCorrection(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Reject corrections whose length blows up vs the input — likely hallucination.
    /// Pure function — testable.
    static func isLengthSane(raw: String, corrected: String, multiplier: Int) -> Bool {
        let rawLen = raw.trimmingCharacters(in: .whitespacesAndNewlines).count
        let corLen = corrected.trimmingCharacters(in: .whitespacesAndNewlines).count
        guard rawLen > 0 else { return false }
        return corLen <= rawLen * multiplier
    }

    @MainActor
    func cancelAll() {
        inFlight.removeAll()
        partials.removeAll()
    }

    #if DEBUG
    /// Cheap self-checks — called once at app launch in DEBUG to catch regressions
    /// in the pure helper logic. Crashes in debug if any invariant is wrong.
    static func runSelfChecks() {
        assert(shouldCorrect(text: "你好世界", minLength: 4) == true)
        assert(shouldCorrect(text: "嗯", minLength: 4) == false)
        assert(shouldCorrect(text: "   ", minLength: 4) == false)
        assert(shouldCorrect(text: "abcd", minLength: 4) == true)     // boundary
        assert(shouldCorrect(text: "abc", minLength: 4) == false)     // boundary
        assert(isUsableCorrection("你好世界") == true)
        assert(isUsableCorrection("") == false)
        assert(isUsableCorrection("   ") == false)
        assert(isUsableCorrection("\n\t ") == false)
        assert(isLengthSane(raw: "在 kubernet es 上", corrected: "在 Kubernetes 上", multiplier: 3) == true)
        assert(isLengthSane(raw: "你好", corrected: String(repeating: "x", count: 200), multiplier: 3) == false)
        assert(isLengthSane(raw: "", corrected: "anything", multiplier: 3) == false)
    }
    #endif
}
