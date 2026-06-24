# Live Transcript LLM Correction — Design

## Context

The live transcript during recording is produced by `SFSpeechRecognizer` in on-device mode (`requiresOnDeviceRecognition = true`). This is Apple's small, offline model and it visibly struggles with:

- Chinese homophones (在/再, 你/您, 一生/医生)
- Code-switched technical terms ("用 Kubernetes 部署")
- Proper nouns, product names, people's names
- Punctuation and sentence segmentation (iOS 16+ `addsPunctuation` is weak)

The user wants a Tencent-Meeting-style experience: a draft transcript appears live as they speak, and a corrected version replaces it a few seconds later.

The DeepSeno iOS app already has all the plumbing — `APIClient` for REST, `SSEClient` for streamed responses, and a paired desktop "second brain" that holds the user's LLM keys and prior context. The natural fit is to make the desktop do the correction.

## Goal & non-goals

**Goal:** Each VAD-finalized segment produced by `LiveTranscriber` gets sent to the desktop for correction; the corrected text replaces the segment text in place, with a small "已校正" marker.

**Non-goals (v1):**
- Re-transcribing the audio with Whisper on the desktop. v1 is text-only LLM polish — it covers the 80/20 of user pain (punctuation, homophones, mixed-language). Audio re-transcription is a future "重档" mode.
- Correcting unfinalized segments. Only segments where `isFinal == true` are sent. Touching the live segment would cause jarring rewrites mid-speech.
- Working when the desktop isn't connected. We silently keep the raw text — no error UI.
- iOS-side LLM. Out of scope.
- Configuring a separate correction model on iOS. v1 uses whatever model the desktop is already configured with.

## Architecture

```
┌──────────────────────── iOS ────────────────────────┐    ┌─────────── Desktop ───────────┐
│                                                     │    │                               │
│  AudioRecorder ──buf──> LiveTranscriber             │    │                               │
│                            │                        │    │                               │
│                            │ VAD-end on segment N   │    │                               │
│                            ▼                        │    │                               │
│                   TranscriptCorrector ──── POST ────┼───▶│  /api/transcript/correct      │
│                            ▲                        │    │  (SSE: chunk events)          │
│                            │ SSE chunks             │    │           │                   │
│                            └────────────────────────┼────┼───────────┘                   │
│                                                     │    │           │                   │
│  CaptureView observes segments[].correctedText      │    │  LLM (current chat model)     │
│                                                     │    │                               │
└─────────────────────────────────────────────────────┘    └───────────────────────────────┘
```

A new service `TranscriptCorrector` owns:
- An async work queue keyed by segment id
- The SSE call to the desktop
- Writing the streamed corrected text back into the matching segment

`LiveTranscriber` notifies `TranscriptCorrector` whenever a segment transitions to `isFinal = true`. The two are kept separate so the speech-recognition lifecycle remains untouched.

## Data model

`TranscriptSegment` gains two fields:

```swift
struct TranscriptSegment: Identifiable {
    let id = UUID()
    var text: String                  // raw ASR text (unchanged behavior)
    let timestamp: TimeInterval
    var endTimestamp: TimeInterval
    var isFinal: Bool

    // NEW
    var correctedText: String? = nil  // nil = not corrected yet (or failed)
    var correctionState: CorrectionState = .none
}

enum CorrectionState {
    case none           // not eligible / desktop offline / disabled
    case pending        // queued, request in flight
    case streaming      // SSE chunks arriving
    case done           // corrected text final
    case failed         // give up silently, fall back to raw text
}
```

Existing `text: String` stays as the source of truth for the raw draft. The UI prefers `correctedText` when present, otherwise falls back to `text`. This keeps every existing consumer of `text` working.

## API contract (desktop endpoint)

New endpoint on the paired desktop server:

```
POST /api/transcript/correct
Authorization: Bearer <token>
Content-Type: application/json

{
  "segmentId": "<uuid>",
  "text": "在 kubernet es 上部署 我 们 的 服务",
  "locale": "zh-Hans" | "en-US" | "multilingual",
  "context": [
    "之前一段的最终文本",
    "再之前一段的最终文本"
  ]
}
```

Response is an SSE stream identical in shape to `/api/query-stream` so we can reuse `SSEClient`:

```
data: {"type":"chunk","text":"在 Kubernetes "}
data: {"type":"chunk","text":"上部署我们的服务。"}
data: {"type":"done"}
```

Errors: HTTP 5xx → iOS marks segment `.failed` and keeps raw text. No retry.

Server-side prompt (for design clarity, not part of iOS work):

> You are correcting an automatic speech-recognition transcript. The user is a native Chinese/English bilingual speaker. Fix homophones, restore correct casing for proper nouns and technical terms, add appropriate punctuation, and remove filler words (嗯, 啊, you know). Do not change meaning, do not add information, do not translate. Output only the corrected text.

Previous segments are included as read-only context so cross-segment proper-noun consistency works.

## TranscriptCorrector

```swift
@Observable
final class TranscriptCorrector {
    weak var transcriber: LiveTranscriber?
    private let api: APIClient            // for host/port/token
    private let sse: SSEClient
    private var inFlight: [UUID: Task<Void, Never>] = [:]
    private let contextWindowSize = 3     // last 3 finalized segments as context
    private let minLength = 4             // skip ultra-short segments

    func enqueue(segmentId: UUID)
    func cancelAll()
}
```

Lifecycle:
- `LiveTranscriber.endSegment()` calls `corrector?.enqueue(segmentId:)` after marking the segment final.
- `enqueue` skips when: desktop not connected, correction disabled in Settings, segment text shorter than `minLength`, or this segment already in flight / done.
- It captures the locale, builds the context (last 3 finalized segments' `correctedText ?? text`), and starts an SSE task.
- As `chunk` events arrive, it appends to `segments[i].correctedText` and sets state to `.streaming`. On `done` → `.done`. On error → `.failed`.
- On `LiveTranscriber.stop()`, in-flight corrections are NOT cancelled — we want them to finish so the saved recording has the corrected text. But if the recording is discarded, `cancelAll()` is called.

Concurrency model: `TranscriptCorrector` is `@Observable` (no `@MainActor`, per the project's Swift-6 rule about AttributeGraph and background access). All segment mutations happen on `MainActor` via a small `@MainActor` helper that updates `transcriber?.segments[index]` — segments are owned by `LiveTranscriber`.

## UX behavior

### During recording

The transcript bubble list (already implemented per `2026-03-30-live-transcript-scroll-design.md`) renders:

- **While `correctionState == .none` or `.pending`**: raw `text` only, no marker.
- **While `.streaming`**: render `correctedText` (partial) — the SSE stream gives us word-by-word, so the bubble grows in place. A subtle pulsing dot at the right edge of the bubble shows "correcting".
- **When `.done`**: render `correctedText`, plus a small ✨ marker at the top-right corner of the bubble. The transition from raw → corrected uses a 200ms cross-fade so the text doesn't snap jarringly.
- **When `.failed`**: render raw `text`, no marker. Silent.

### Settings

A new toggle in `SettingsView`:

```
转写校正 (Live transcript correction)
[On] Polish each segment with the desktop's AI after recording finishes the sentence.
```

Default: **on** if the desktop is paired, otherwise the toggle is disabled with a helper line "需要先配对桌面端".

### After recording

When the user saves the recording, the final segment list goes through the upload pipeline. We send `correctedText ?? text` as the segment text to the desktop (it's the "good" version). Raw `text` is kept locally in the SwiftData store too, in case we want to A/B compare later — but not surfaced in UI.

## Failure & edge cases

| Case | Behavior |
|------|----------|
| Desktop offline at segment-finalize time | Skip, leave `correctionState = .none`, no marker |
| Desktop goes offline mid-stream | Mark `.failed`, keep whatever was received as the raw `text` (don't overwrite) |
| User stops recording while N corrections in flight | Let them finish, update segments as results arrive (post-stop) |
| User discards recording | `cancelAll()` |
| Segment text < 4 chars | Skip — LLM rewrites tend to over-correct tiny fragments |
| Correction produces text > 3× raw length | Reject — almost certainly a hallucination. Mark `.failed`. |
| Same segment enqueued twice | No-op via `inFlight` map |
| User toggles setting off mid-recording | New segments stop being enqueued; in-flight ones complete |

## Testing

- **Unit**: `TranscriptCorrector` enqueue/dedupe logic with a fake `SSEClient` that emits scripted chunk/done/error events. Verify state transitions and final segment text.
- **Unit**: Length-ratio sanity check rejects hallucinated long outputs.
- **Integration (manual)**: Record a paragraph with deliberate homophones / mixed-language. Verify replacement happens within 2-5s after VAD-end and the marker appears. Test desktop-offline path.

## Open items punted to v2

1. **Audio re-transcription (重档模式)**. Add an optional flag to also send the segment's WAV slice; desktop runs Whisper-large then LLM polish. Bigger latency, far better on proper nouns.
2. **Cross-segment retroactive correction**. If segment N+1 introduces a name, retroactively fix segment N. Needs a different data model.
3. **Per-correction model picker on iOS**. Let user pick cheaper Haiku for correction even if chat uses Opus. Needs server support and a model list endpoint.
