# DeepSeno iOS - Project Context

## Project
DeepSeno iOS companion app for the voice-powered "second brain" desktop app. Captures audio, photos, video, text memos and syncs to desktop via local network.

## Tech Stack
- SwiftUI + Swift 6 (strict concurrency)
- SwiftData (local persistence)
- AVFoundation (audio recording via AVAudioEngine)
- Speech framework (SFSpeechRecognizer, on-device live transcription)
- XcodeGen (project.yml → .xcodeproj)

## Architecture
```
Views/ (SwiftUI)
├── Capture/ — Recording UI, waveform, bookmarks
├── Sources/ — Browse recordings, search, detail view
├── Chat/ — AI assistant with markdown rendering
├── Briefing/ — Daily/weekly summaries
├── Settings/ — Connection, pairing, queue management
└── Common/ — ConnectionBadge, StatusBadge, EmptyStateView

ViewModels/ (Observable)
├── AppState — Connection, WebSocket, CaptureQueue
├── CaptureViewModel — Recording, LiveTranscriber, toast
├── ChatViewModel, SourcesViewModel, BriefingViewModel, SettingsViewModel

Services/
├── AudioRecorder — AVAudioEngine + AVAudioFile (WAV 16kHz mono)
├── LiveTranscriber — SFSpeechRecognizer (on-device, zh/en)
├── WebSocketManager — Real-time server events
├── APIClient — REST API with Bearer auth
├── CaptureQueue — Upload queue with retry
├── SSEClient — Streaming chat responses
├── NotificationService — Local push notifications
└── AudioStreamer — WebSocket audio streaming (stub)

Theme/
├── DeepSenoTheme — Colors, fonts, GlassCard modifier
└── I18n — English + Chinese localization
```

## Key Design Decisions
- `@Observable` classes must NOT use `@MainActor` — SwiftUI's AttributeGraph accesses them from background threads, causing `dispatch_assert_queue_fail` crashes in Swift 6
- Timer callbacks use `[weak self]` directly (Sendable warning acceptable), NOT `MainActor.assumeIsolated`
- Cross-thread audio data uses `@unchecked Sendable` lock-protected boxes
- AVAudioEngine replaces AVAudioRecorder to enable single-pipeline recording + live transcription
- WAV format (LinearPCM) used instead of M4A (AAC) — `AVAudioFile` AAC encoding fails on some devices
- Simulator uses WAV too (no AAC encoder available)
- LiveTranscriber disabled on simulator (`#if targetEnvironment(simulator)`)

## Build & Run
```bash
# Development (Simulator)
xcodebuild -scheme DeepSeno -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# Development (Device) — use Xcode Cmd+R with device selected
```

## Release to TestFlight / App Store

**Use the script** (`scripts/release-testflight.sh`). It bumps the build
number, archives, signs, exports, and uploads to App Store Connect in one
command:

```bash
./scripts/release-testflight.sh             # default: bump + upload
./scripts/release-testflight.sh --no-bump   # reuse current build number (retry)
./scripts/release-testflight.sh --no-upload # build IPA only, skip upload
./scripts/release-testflight.sh --validate  # validate IPA without uploading
```

After upload, App Store Connect takes 10–30 min to process. Track at:
https://appstoreconnect.apple.com/apps → DeepSeno → TestFlight.

### Required one-time setup
- App Store Connect API key with **Admin** role (App Manager / Developer
  are NOT sufficient; cloud-managed signing requires Admin).
- Save `.p8` at: `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8`
- Create `.env` in repo root (gitignored):
  ```
  Key ID=<APP_STORE_CONNECT_KEY_ID>
  Issuer ID=<APP_STORE_CONNECT_ISSUER_ID>
  Team ID=<APPLE_TEAM_ID>
  Bundle ID=<APP_BUNDLE_ID>
  Relay Server Base URL=<RELAY_SERVER_BASE_URL>
  Private Key Base64=<BASE64_ENCODED_AUTHKEY_P8>
  ```

### Manual archive (only if scripting unavailable)
```bash
xcodebuild -scheme DeepSeno -destination 'generic/platform=iOS' \
  -configuration Release -archivePath ./build/DeepSeno.xcarchive \
  -allowProvisioningUpdates clean archive
xcodebuild -exportArchive -archivePath ./build/DeepSeno.xcarchive \
  -exportPath ./build/ipa -exportOptionsPlist ExportOptions.plist \
  -allowProvisioningUpdates \
  -authenticationKeyPath ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8 \
  -authenticationKeyID <KEY_ID> -authenticationKeyIssuerID <ISSUER_ID>
```

Output: `build/DeepSeno.xcarchive`, `build/ipa/DeepSeno.ipa`

## Version Update
In `project.yml`:
```yaml
MARKETING_VERSION: "1.5.2"    # User-facing version
CURRENT_PROJECT_VERSION: 8     # Build number
```

## Signing
- Team ID: set locally via `.env` or GitHub Actions secret `APPLE_TEAM_ID`
- Bundle ID: set locally via `.env` or GitHub Actions secret `APP_BUNDLE_ID`; App Store updates use `com.korteqo.app.ios`
- Identity: Apple Development (auto-managed)

## Adding New Files
New `.swift` files must be registered in `DeepSeno.xcodeproj/project.pbxproj` in 4 places:
1. `PBXBuildFile` section
2. `PBXFileReference` section
3. Parent group's `children` array
4. `PBXSourcesBuildPhase` `files` array

Or regenerate project with XcodeGen: `xcodegen generate` (if installed).

## Important Notes
- Audio session: `.playAndRecord` mode with `.allowBluetooth`
- LiveTranscriber uses `Locale.preferredLanguages` to detect Chinese
- Upload sends `Content-Type` based on file extension (mimeType helper)
- Filenames URL-encoded in `X-Filename` header for non-ASCII safety
- Bookmarks sent via `X-Bookmarks` header as JSON array of timestamps (ms)

## Live transcript correction (v1)

Each VAD-finalized segment from `LiveTranscriber` is sent to the paired
desktop via `TranscriptCorrector` for LLM polish. The raw `SFSpeechRecognizer`
draft stays on screen until the corrected version streams back, then the
bubble cross-fades and shows a ✨ marker.

Endpoint contract (desktop side, not yet implemented):

- `POST /api/transcript/correct` — served by the same HTTP server / port as
  `/api/query-stream`. iOS reads host/port/token from `AppState`.
- Auth: `Bearer <token>` (same token as the rest of the API).
- Body:
  ```json
  {
    "segmentId": "<UUID>",
    "text": "raw ASR transcript",
    "locale": "zh-Hans" | "en-US" | "multilingual",
    "context": ["prev finalized segment 1", "prev 2", "prev 3"]
  }
  ```
  - `segmentId` is sent for server-side correlation / logging. iOS does not
    require it in any response field — drop or echo as convenient.
  - `locale = "multilingual"` means the speaker mixes zh and en. v1 treats
    this as "leave language alone, don't translate". The server should not
    force a single output language.
- Response: SSE stream with the same envelope as `/api/query-stream`:
  - `data: {"type":"chunk","text":"..."}` (zero or more; empty `text` tolerated).
  - `data: {"type":"done"}` (end of stream).
  - `data: {"type":"error","error":"..."}` (server-side failure).
- Timeout: iOS request timeout is 30 s end-to-end. Streams that take longer
  are marked `.failed` on the iOS side and silently revert to raw text.

Suggested server prompt: "Correct ASR errors in the supplied text. Fix
homophones, restore casing for proper nouns and technical terms, add
appropriate punctuation, remove filler words (嗯, 啊, you know). Do not
change meaning, do not translate, do not add information. Output only
the corrected text." Use `context` as read-only prior-segment text for
proper-noun consistency across segments.

iOS-side guardrails:
- Skip segments whose trimmed length < 4 chars.
- Reject corrections whose length > 3× the raw input (treated as hallucination).
- Honor `transcription_correction_enabled` UserDefault (default true).
- Silent fallback to raw text on any failure (no error UI).
- In-flight corrections at recording stop are intentionally NOT cancelled,
  so the saved transcript view reflects late-arriving corrections.

Toggle: Settings → "AI 校正实时转写" (`UserDefaults["transcription_correction_enabled"]`).
