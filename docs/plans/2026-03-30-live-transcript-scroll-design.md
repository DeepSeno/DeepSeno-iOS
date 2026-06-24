# Live Transcript Scrollable Preview — Design

## Context

The current live transcript preview during recording shows a single text string truncated to 4 lines with no timestamps and no scrolling. Users cannot see the full transcript or know which part of the recording corresponds to which text.

## Design

### Layout Change

Split CaptureView into two halves during recording:
- **Top**: Waveform + timer + record/pause button + action buttons (compacted)
- **Bottom**: Scrollable chat-bubble transcript panel, auto-scrolls to latest

The transcript panel appears with a slide-up animation when recording starts and hides when recording stops.

### Data Model

Replace `LiveTranscriber.text: String` with a segment array:

```swift
struct TranscriptSegment: Identifiable {
    let id = UUID()
    var text: String              // Segment text
    var timestamp: TimeInterval   // Start time in recording (seconds)
    var isFinal: Bool             // Whether SFSpeechRecognizer returned final result
}
```

- `LiveTranscriber.segments: [TranscriptSegment]` — replaces `text: String`
- Keep `text` as computed property (joined segments) for backward compat if needed

### Segmentation Logic

Based on SFSpeechRecognizer recognition rounds:
- **Partial result**: Update the last segment's `.text`
- **Final result**: Mark last segment as `isFinal = true`
- **New recognition round starts**: Create new segment with `timestamp = recorder.duration`

### Bubble UI

Each `TranscriptSegment` renders as a row:
- **Left**: Timestamp label (e.g. `0:32`), monospace, secondary color, top-aligned
- **Right**: Glass card bubble with segment text, primary text color
- **Last segment** with `isFinal == false`: Show blinking cursor at end
- **ScrollViewReader** + `.onChange(of: segments.count)` to auto-scroll to bottom

### Files to Modify

1. `DeepSeno/Services/LiveTranscriber.swift` — New `TranscriptSegment` model, segment array output
2. `DeepSeno/Views/Capture/CaptureView.swift` — Replace `liveTranscriptCard` with scrollable bubble panel

### Not Changed

- AudioRecorder (no changes needed)
- Bookmark functionality
- Upload queue indicator
- RecordButton
