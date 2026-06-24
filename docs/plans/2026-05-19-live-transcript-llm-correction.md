# Live Transcript LLM Correction Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** While recording, send each VAD-finalized transcript segment to the paired desktop over SSE for LLM correction, and replace the bubble's text in place with a ✨ marker.

**Architecture:** A new `TranscriptCorrector` service owns an in-flight queue keyed by `TranscriptSegment.id`. `LiveTranscriber` notifies it when a segment finalizes; the corrector POSTs `(text, locale, last-N-segments-as-context)` to a new desktop SSE endpoint `/api/transcript/correct`, streams chunks back into `segments[i].correctedText`, and the existing `CaptureView` bubble renders `correctedText ?? text` with a sparkle marker when `correctionState == .done`. Silent fallback when the desktop isn't connected.

**Tech Stack:** Swift 6 strict concurrency, `@Observable` ViewModels (no `@MainActor` per project's AttributeGraph rule), `URLSession.bytes(for:)` for SSE consumption (already used in `SSEClient`), `@AppStorage` for the on/off toggle.

**Reference docs:**
- Design: `docs/plans/2026-05-19-live-transcript-llm-correction-design.md`
- Project rules: `CLAUDE.md` (Swift 6 + AttributeGraph + new-file pbxproj registration)

**Verification strategy:** No test target exists in this project (`DeepSenoTests/` is empty). The plan uses:
- `#if DEBUG` self-checks (`TranscriptCorrector.runSelfChecks()` called from app launch) for pure logic
- Scripted manual simulator runs for service + UI behavior
- `xcodebuild build` after every task to catch type / concurrency errors

Do NOT add a test target — that's out of scope. If a task says "verify", it means "follow the steps under Verification".

---

## Task 1: Extend `TranscriptSegment` with correction fields

**Files:**
- Modify: `DeepSeno/Services/LiveTranscriber.swift:5-11`

**Step 1: Add the enum and fields**

Replace the `TranscriptSegment` struct (lines 5-11) with:

```swift
enum CorrectionState: Equatable {
    case none        // not eligible / disabled / desktop offline
    case pending     // queued, request not yet started
    case streaming   // SSE chunks arriving
    case done        // corrected text final
    case failed      // give up silently, fall back to raw text
}

struct TranscriptSegment: Identifiable {
    let id = UUID()
    var text: String                          // raw ASR text
    let timestamp: TimeInterval
    var endTimestamp: TimeInterval
    var isFinal: Bool

    var correctedText: String? = nil          // nil until correction starts
    var correctionState: CorrectionState = .none

    /// The text to display: corrected if available, else raw.
    var displayText: String {
        correctedText ?? text
    }
}
```

**Step 2: Build**

```bash
xcodebuild -scheme DeepSeno -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED. Existing call sites (`segment.text`) still compile — `text` is unchanged.

**Step 3: Commit**

```bash
git add DeepSeno/Services/LiveTranscriber.swift
git commit -m "feat(transcript): add correctedText + correctionState to TranscriptSegment"
```

---

## Task 2: Add SSE-correct method on a new `TranscriptCorrectionClient`

**Files:**
- Create: `DeepSeno/Services/TranscriptCorrectionClient.swift`
- Modify: `DeepSeno.xcodeproj/project.pbxproj` (4 places — see CLAUDE.md "Adding New Files")

**Step 1: Write the client**

Modeled on `SSEClient` but with chunk-only event handling (no sources / sessionId):

```swift
import Foundation

/// Calls the desktop's POST /api/transcript/correct endpoint and streams
/// back word-by-word corrected text. The endpoint speaks SSE with the same
/// `data: {"type":"chunk","text":"..."}` envelope as /api/query-stream so
/// that we can reuse the consumption pattern, but it returns no sources.
actor TranscriptCorrectionClient {
    struct Request: Encodable {
        let segmentId: String
        let text: String
        let locale: String
        let context: [String]
    }

    enum CorrectionError: Error {
        case invalidURL
        case invalidResponse(Int)
        case serverError(String)
    }

    func stream(
        host: String,
        port: Int,
        token: String,
        request: Request,
        onChunk: @Sendable @escaping (String) -> Void
    ) async throws {
        guard let url = URL(string: "http://\(host):\(port)/api/transcript/correct") else {
            throw CorrectionError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(request)
        req.timeoutInterval = 30

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw CorrectionError.invalidResponse(-1)
        }
        guard (200...299).contains(http.statusCode) else {
            throw CorrectionError.invalidResponse(http.statusCode)
        }

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonStr = String(line.dropFirst(6))
            guard let data = jsonStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else { continue }

            switch type {
            case "chunk":
                if let text = json["text"] as? String { onChunk(text) }
            case "done":
                return
            case "error":
                throw CorrectionError.serverError(json["error"] as? String ?? "unknown")
            default:
                break
            }
        }
    }
}
```

**Step 2: Register the new file in `project.pbxproj`** (4 sections per `CLAUDE.md`):

Find the matching pattern for `SSEClient.swift` in `DeepSeno.xcodeproj/project.pbxproj` and replicate for `TranscriptCorrectionClient.swift` in:
1. `PBXBuildFile` section
2. `PBXFileReference` section
3. The `Services` group's `children` array
4. `PBXSourcesBuildPhase` `files` array

Use this command to find existing entries to copy:

```bash
grep -n "SSEClient" DeepSeno.xcodeproj/project.pbxproj
```

Generate fresh UUIDs (24-char hex). Each new file needs two new UUIDs (one for `PBXBuildFile`, one for `PBXFileReference`).

**Step 3: Build**

```bash
xcodebuild -scheme DeepSeno -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED.

**Step 4: Commit**

```bash
git add DeepSeno/Services/TranscriptCorrectionClient.swift DeepSeno.xcodeproj/project.pbxproj
git commit -m "feat(transcript): SSE client for /api/transcript/correct"
```

---

## Task 3: Add `correction_enabled` UserDefault + Settings toggle

**Files:**
- Modify: `DeepSeno/Views/Settings/SettingsView.swift` (add toggle next to existing `transcription_locale` Picker)

**Step 1: Find the insertion point**

```bash
grep -n "transcription_locale\|Section\|Toggle" DeepSeno/Views/Settings/SettingsView.swift
```

Open the file and find the section that contains the `transcription_locale` Picker. The toggle goes in the same section, above the Picker.

**Step 2: Add `@AppStorage` declaration**

Near the existing `@AppStorage("transcription_locale")` (line 10), add:

```swift
@AppStorage("transcription_correction_enabled") private var correctionEnabled: Bool = true
```

**Step 3: Add the toggle**

Inside the transcription `Section`, above the existing Picker, add:

```swift
Toggle(isOn: $correctionEnabled) {
    VStack(alignment: .leading, spacing: 2) {
        Text(i18n.t.transcriptionCorrectionTitle)
        Text(i18n.t.transcriptionCorrectionHint)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
```

**Step 4: Add i18n strings**

In `DeepSeno/Theme/I18n.swift`, add to both English and Chinese tables:

- English: `transcriptionCorrectionTitle = "Polish transcript with AI"`, `transcriptionCorrectionHint = "After each sentence, the desktop AI cleans up homophones, punctuation, and proper nouns."`
- Chinese: `transcriptionCorrectionTitle = "AI 校正实时转写"`, `transcriptionCorrectionHint = "每句话结束后，由桌面端 AI 修正同音字、标点和专有名词。"`

Use `grep -n "transcriptionLanguage\|transcription" DeepSeno/Theme/I18n.swift` to find the right spot — keep the new keys grouped with existing transcription strings.

**Step 5: Build and visually verify**

```bash
xcodebuild -scheme DeepSeno -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -20
```

Then in Xcode preview or sim: Settings → see new toggle above the language picker.

**Step 6: Commit**

```bash
git add DeepSeno/Views/Settings/SettingsView.swift DeepSeno/Theme/I18n.swift
git commit -m "feat(settings): toggle for AI transcript correction"
```

---

## Task 4: Build the `TranscriptCorrector` skeleton (eligibility + dedupe)

**Files:**
- Create: `DeepSeno/Services/TranscriptCorrector.swift`
- Register in `DeepSeno.xcodeproj/project.pbxproj` (4 places, same procedure as Task 2)

**Step 1: Write the skeleton**

This task writes just the eligibility + dedupe logic — no SSE wiring yet. SSE comes in Task 5. We test the logic via a `#if DEBUG` `runSelfChecks()` method.

```swift
import Foundation

/// Coordinates LLM correction of finalized transcript segments.
///
/// Lifecycle: created when recording starts, retained for the duration of
/// the recording, and `cancelAll()`-ed if the recording is discarded.
/// In-flight corrections at stop() are intentionally NOT cancelled — we
/// want the saved transcript view (post-stop) to reflect them.
@Observable
final class TranscriptCorrector: @unchecked Sendable {
    weak var transcriber: LiveTranscriber?

    private let host: String
    private let port: Int
    private let token: String
    private let client = TranscriptCorrectionClient()

    /// Segments currently being corrected. Read on MainActor only.
    private var inFlight: Set<UUID> = []

    /// How many previous finalized segments to include as context.
    private let contextWindowSize = 3
    /// Skip segments shorter than this (LLMs over-correct tiny fragments).
    private let minLength = 4
    /// Reject corrections whose length blows up — likely hallucination.
    private let maxLengthMultiplier = 3

    init(host: String, port: Int, token: String) {
        self.host = host
        self.port = port
        self.token = token
    }

    /// Decide whether a segment is a candidate for correction.
    /// Pure function — testable.
    static func shouldCorrect(text: String, minLength: Int) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= minLength
    }

    /// Reject corrections whose length is wildly different from the input.
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
    }

    #if DEBUG
    /// Cheap self-checks — call once at app launch in DEBUG to catch regressions.
    static func runSelfChecks() {
        assert(shouldCorrect(text: "你好世界", minLength: 4) == true)
        assert(shouldCorrect(text: "嗯", minLength: 4) == false)
        assert(shouldCorrect(text: "   ", minLength: 4) == false)
        assert(isLengthSane(raw: "在 kubernet es 上", corrected: "在 Kubernetes 上", multiplier: 3) == true)
        assert(isLengthSane(raw: "你好", corrected: String(repeating: "x", count: 200), multiplier: 3) == false)
        assert(isLengthSane(raw: "", corrected: "anything", multiplier: 3) == false)
    }
    #endif
}
```

**Step 2: Register in pbxproj**

Same procedure as Task 2 — replicate the `SSEClient.swift` entry pattern.

**Step 3: Call `runSelfChecks()` at app launch**

```bash
find DeepSeno -name "*App.swift" -o -name "DeepSenoApp.swift" | head
```

In the app entry point (look for `@main`), add to `init()`:

```swift
init() {
    #if DEBUG
    TranscriptCorrector.runSelfChecks()
    #endif
}
```

**Step 4: Build & verify self-checks pass**

```bash
xcodebuild -scheme DeepSeno -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -20
```

Then launch the app in the simulator — if any `assert` fails the process traps in debug.

```bash
xcrun simctl boot "iPhone 17 Pro" 2>/dev/null || true
xcrun simctl install booted ~/Library/Developer/Xcode/DerivedData/DeepSeno-*/Build/Products/Debug-iphonesimulator/DeepSeno.app
xcrun simctl launch booted com.enmooy.deepseno
```

Expected: app launches without crashing.

**Step 5: Commit**

```bash
git add DeepSeno/Services/TranscriptCorrector.swift DeepSeno.xcodeproj/project.pbxproj DeepSeno/DeepSenoApp.swift
git commit -m "feat(transcript): TranscriptCorrector skeleton with eligibility checks"
```

---

## Task 5: Wire SSE streaming through `TranscriptCorrector.enqueue`

**Files:**
- Modify: `DeepSeno/Services/TranscriptCorrector.swift`

**Step 1: Add `enqueue` and the per-segment Task**

Inside the class, add:

```swift
@MainActor
func enqueue(segmentId: UUID, locale: String) {
    guard let transcriber else { return }
    guard let idx = transcriber.segments.firstIndex(where: { $0.id == segmentId }) else { return }
    let segment = transcriber.segments[idx]

    // Already running or finished
    guard segment.correctionState == .none else { return }
    guard !inFlight.contains(segmentId) else { return }

    // Eligibility
    guard Self.shouldCorrect(text: segment.text, minLength: minLength) else { return }

    // Setting check
    let enabled = UserDefaults.standard.object(forKey: "transcription_correction_enabled") as? Bool ?? true
    guard enabled else { return }

    // Build context: last N finalized segments BEFORE this one
    let context: [String] = transcriber.segments
        .prefix(idx)
        .filter { $0.isFinal }
        .suffix(contextWindowSize)
        .map { $0.displayText }

    inFlight.insert(segmentId)
    transcriber.segments[idx].correctionState = .pending

    let request = TranscriptCorrectionClient.Request(
        segmentId: segmentId.uuidString,
        text: segment.text,
        locale: locale,
        context: context
    )

    Task { [weak self] in
        guard let self else { return }
        await self.runCorrection(segmentId: segmentId, rawText: segment.text, request: request)
    }
}

private func runCorrection(
    segmentId: UUID,
    rawText: String,
    request: TranscriptCorrectionClient.Request
) async {
    var accumulated = ""
    var sawAnyChunk = false

    do {
        try await client.stream(
            host: host, port: port, token: token, request: request
        ) { chunk in
            // SSE callback is @Sendable — bounce to MainActor for segment writes.
            Task { @MainActor [weak self] in
                guard let self else { return }
                accumulated += chunk
                sawAnyChunk = true
                self.applyChunk(segmentId: segmentId, accumulated: accumulated)
            }
        }
        await self.finalize(segmentId: segmentId, rawText: rawText, finalText: accumulated, success: sawAnyChunk)
    } catch {
        await self.finalize(segmentId: segmentId, rawText: rawText, finalText: accumulated, success: false)
    }
}

@MainActor
private func applyChunk(segmentId: UUID, accumulated: String) {
    guard let transcriber,
          let idx = transcriber.segments.firstIndex(where: { $0.id == segmentId }) else { return }
    transcriber.segments[idx].correctedText = accumulated
    transcriber.segments[idx].correctionState = .streaming
}

@MainActor
private func finalize(segmentId: UUID, rawText: String, finalText: String, success: Bool) {
    inFlight.remove(segmentId)
    guard let transcriber,
          let idx = transcriber.segments.firstIndex(where: { $0.id == segmentId }) else { return }

    if success, !finalText.isEmpty,
       Self.isLengthSane(raw: rawText, corrected: finalText, multiplier: maxLengthMultiplier) {
        transcriber.segments[idx].correctedText = finalText
        transcriber.segments[idx].correctionState = .done
    } else {
        // Hallucination / network / empty — fall back to raw text silently.
        transcriber.segments[idx].correctedText = nil
        transcriber.segments[idx].correctionState = .failed
    }
}
```

Note the closure-captured `accumulated` and `sawAnyChunk` vars — they're only touched inside `Task { @MainActor }` blocks. The callback hops to MainActor, so there's no data race despite the capture, but make sure they're declared `var` outside the `do` block so the catch handler can finalize with whatever we got.

Actually, refactor: move `accumulated` and `sawAnyChunk` into an `@MainActor` actor-isolated dictionary keyed by `segmentId`, since closures capturing `var` across actor boundaries is a Swift 6 concurrency mistake. Use:

```swift
@MainActor private var partials: [UUID: String] = [:]
```

And the callback does `partials[segmentId, default: ""] += chunk`, then `applyChunk(segmentId: segmentId, accumulated: partials[segmentId] ?? "")`. `finalize` reads `partials[segmentId]` and removes the entry. Update the code above accordingly during implementation — if `xcodebuild` complains about Sendable, this is the fix.

**Step 2: Build**

```bash
xcodebuild -scheme DeepSeno -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -30
```

Expected: BUILD SUCCEEDED. If you see Sendable / actor-isolation errors, apply the `partials` dictionary refactor.

**Step 3: Commit**

```bash
git add DeepSeno/Services/TranscriptCorrector.swift
git commit -m "feat(transcript): SSE streaming corrector with hallucination guard"
```

---

## Task 6: Hook `LiveTranscriber` to notify the corrector on segment finalize

**Files:**
- Modify: `DeepSeno/Services/LiveTranscriber.swift`

**Step 1: Add a hook closure**

In `LiveTranscriber` (right after the existing properties around line 105):

```swift
/// Called whenever a segment is finalized (isFinal flips to true).
/// Set by CaptureViewModel after start().
var onSegmentFinalized: ((UUID, String) -> Void)?

/// Locale identifier set during start() — used to tell the corrector which
/// language the segment is in. For multilingual mode this is "multilingual"
/// even though two lanes are running.
private(set) var activeLocale: String = "en-US"
```

**Step 2: Capture the locale during `start()`**

In the `start(recorder:)` method, just after the `let localeIds: [String]` switch (around line 135), add:

```swift
self.activeLocale = override.isEmpty
    ? (Locale.preferredLanguages.contains { $0.hasPrefix("zh") } ? "zh-Hans" : "en-US")
    : override
```

**Step 3: Fire the hook on segment finalization**

Find `endSegment()` (around line 230) and add the callback at the end:

```swift
private func endSegment() {
    isForwardingAudio = false

    if let last = segments.indices.last, !segments[last].isFinal {
        segments[last].endTimestamp = silenceStart
        segments[last].isFinal = true
        let finalizedId = segments[last].id
        let finalizedText = segments[last].text
        // Notify the corrector; it decides eligibility internally.
        if !finalizedText.isEmpty {
            onSegmentFinalized?(finalizedId, activeLocale)
        }
    }

    for lane in lanes { lane.endTask() }
}
```

Also at the end of `stop()` (where the last not-final segment is force-finalized), fire the hook for that segment too:

```swift
if let lastIndex = segments.indices.last, !segments[lastIndex].isFinal {
    segments[lastIndex].isFinal = true
    let finalizedId = segments[lastIndex].id
    let finalizedText = segments[lastIndex].text
    if !finalizedText.isEmpty {
        onSegmentFinalized?(finalizedId, activeLocale)
    }
}
```

**Step 4: Build**

```bash
xcodebuild -scheme DeepSeno -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -20
```

**Step 5: Commit**

```bash
git add DeepSeno/Services/LiveTranscriber.swift
git commit -m "feat(transcript): expose onSegmentFinalized hook + activeLocale"
```

---

## Task 7: Wire the corrector into `CaptureViewModel`

**Files:**
- Modify: `DeepSeno/ViewModels/CaptureViewModel.swift`

**Step 1: Add an optional corrector property**

After `let transcriber = LiveTranscriber()` (line 16):

```swift
var corrector: TranscriptCorrector?
```

**Step 2: Instantiate corrector at recording start (if connected)**

Inside `toggleRecording`, in the `else` branch (start path), after `transcriber.start(recorder: recorder)` (line 83):

```swift
// Live-correction setup — only if the desktop is paired AND the user
// hasn't turned the toggle off.
let correctionOn = UserDefaults.standard.object(
    forKey: "transcription_correction_enabled"
) as? Bool ?? true
if correctionOn,
   webSocket.isConnected,
   let host = appState.connectionHost,
   let port = appState.connectionPort,
   let token = appState.connectionToken {
    let cor = TranscriptCorrector(host: host, port: port, token: token)
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
```

Check the exact property names on `AppState` — adjust `connectionHost` / `connectionPort` / `connectionToken` to match what's there.

```bash
grep -n "connectionHost\|connectionPort\|connectionToken\|host\b\|port\b" DeepSeno/ViewModels/AppState.swift | head
```

**Step 3: Tear down on stop**

Inside the `if recorder.isRecording` branch, after `transcriber.stop()` (line 31), do NOT cancel in-flight — only drop our reference to the corrector AFTER a delay so in-flight corrections can still write back to segments. Simpler approach: keep the property nil-able and let it deallocate naturally when CaptureViewModel goes away. Add only the hook cleanup:

```swift
transcriber.onSegmentFinalized = nil
// Keep `corrector` retained so in-flight SSE streams finish.
// It will be replaced (and old one dropped) on the next recording.
```

**Step 4: Build**

```bash
xcodebuild -scheme DeepSeno -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -20
```

If `connectionPort` doesn't exist as an Int on `AppState`, hard-code 8080 or expose a `port` accessor — check what `APIClient` is given today.

**Step 5: Commit**

```bash
git add DeepSeno/ViewModels/CaptureViewModel.swift
git commit -m "feat(transcript): wire TranscriptCorrector into capture flow"
```

---

## Task 8: Update the transcript bubble UI

**Files:**
- Modify: `DeepSeno/Views/Capture/CaptureView.swift:332-364` (the `transcriptBubble` function)

**Step 1: Replace `transcriptBubble`**

```swift
private func transcriptBubble(segment: TranscriptSegment) -> some View {
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

                if segment.correctionState == .done {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DeepSenoTheme.accentGreen)
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                } else if segment.correctionState == .streaming
                          || segment.correctionState == .pending {
                    // Subtle pulsing dot while correction is in flight.
                    Circle()
                        .fill(DeepSenoTheme.accentGreen)
                        .frame(width: 5, height: 5)
                        .opacity(0.6)
                        .scaleEffect(segment.correctionState == .streaming ? 1.0 : 0.7)
                        .animation(
                            .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                            value: segment.correctionState
                        )
                }
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
```

Note: `segment.text` → `segment.displayText` in the body. The 200ms `animation(_:value:)` modifier produces the cross-fade when `displayText` changes from raw → corrected.

**Step 2: Build**

```bash
xcodebuild -scheme DeepSeno -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -20
```

**Step 3: Commit**

```bash
git add DeepSeno/Views/Capture/CaptureView.swift
git commit -m "feat(transcript): bubble shows corrected text with sparkle marker"
```

---

## Task 9: End-to-end manual verification (no desktop endpoint yet — simulate)

The desktop `/api/transcript/correct` endpoint is in a separate repo. Until it exists, verify the iOS happy/sad paths by:

**A. Sad path (desktop offline)**

1. In iOS sim, leave the desktop unpaired (Settings shows "未连接").
2. Start recording. Speak two sentences with deliberate homophones, e.g.:
   - "在 Kubernetes 上部署我们的服务"
   - "今天天气怎么样"
3. Stop recording.
4. Verify: every bubble has NO sparkle, NO pulsing dot. Raw `SFSpeechRecognizer` text shows unchanged. No errors in console.

```bash
xcrun simctl spawn booted log stream --predicate 'process == "DeepSeno"' | grep -i "transcript\|correct"
```

Expected: no `TranscriptCorrector` activity beyond "skipped" log lines (add a `print` in the disabled branch if needed for this verification, then remove).

**B. Happy path (with a fake local endpoint)**

In a shell, spin up a one-shot SSE server that fakes corrections:

```bash
python3 -c "
from http.server import HTTPServer, BaseHTTPRequestHandler
import json, time
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get('Content-Length', 0))
        body = json.loads(self.rfile.read(length))
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        corrected = body['text'].upper()
        for ch in corrected:
            self.wfile.write(f'data: {{\"type\":\"chunk\",\"text\":\"{ch}\"}}\n\n'.encode())
            self.wfile.flush()
            time.sleep(0.05)
        self.wfile.write(b'data: {\"type\":\"done\"}\n\n')
HTTPServer(('0.0.0.0', 8080), H).serve_forever()
" &
```

Pair the iOS app to `localhost:8080` with any non-empty token (the fake server ignores auth). Record a sentence. Expected:
- Bubble appears with raw text first.
- After VAD-end (~0.8s silence), pulsing dot appears.
- Text gets replaced char-by-char with UPPERCASED version, cross-fading.
- When done, dot → sparkle ✨.

Kill the fake server: `kill %1`

If both paths work, the iOS side is done.

**No commit for this task** — verification only.

---

## Task 10: Update CLAUDE.md with the new desktop endpoint contract

**Files:**
- Modify: `CLAUDE.md`

**Step 1: Add a section under "Important Notes"**

```markdown
## Live transcript correction (v1)

Each VAD-finalized segment from `LiveTranscriber` is sent to the paired
desktop via `TranscriptCorrector` for LLM polish. Endpoint contract:

- `POST /api/transcript/correct`
- Auth: `Bearer <token>`
- Body: `{"segmentId":"<uuid>","text":"...","locale":"zh-Hans|en-US|multilingual","context":["prev seg 1","prev seg 2","prev seg 3"]}`
- Response: SSE stream of `{"type":"chunk","text":"..."}` events ending in `{"type":"done"}` or `{"type":"error","error":"..."}`
- Hallucination guard: iOS rejects corrections longer than 3× the input.

If the endpoint is down or returns non-2xx, iOS silently falls back to the raw
`SFSpeechRecognizer` text. Toggle: Settings → "AI 校正实时转写"
(`UserDefaults["transcription_correction_enabled"]`).
```

**Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: live transcript correction endpoint contract"
```

---

## Done criteria

- [ ] `TranscriptSegment` has `correctedText` and `correctionState` fields
- [ ] `TranscriptCorrectionClient` calls `/api/transcript/correct` and streams chunks
- [ ] `TranscriptCorrector` debounces re-enqueues, respects the setting, falls back silently on error, and rejects 3×-blowups
- [ ] Settings toggle controls whether new segments get corrected (in-flight ones still finish)
- [ ] Bubble UI shows raw text → corrected text cross-fade with pulsing-dot → sparkle marker
- [ ] App launches with `runSelfChecks()` asserts passing
- [ ] Sad-path manual test: no desktop → no UI artifacts, no crashes
- [ ] Happy-path manual test: fake SSE server → bubbles update char-by-char, sparkle appears

## Out of scope (per design doc)

- Audio re-transcription on the desktop (重档 mode)
- Cross-segment retroactive correction
- Per-correction model picker on iOS
- Desktop endpoint implementation (separate repo)
- iOS test target setup
