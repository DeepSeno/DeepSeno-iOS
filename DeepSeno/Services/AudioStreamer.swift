import Foundation
import AVFoundation

/// Streams audio to desktop for real-time transcription via WebSocket.
///
/// Currently a stub — streaming will be enabled when the desktop backend
/// implements the transcribe:start/partial/final WebSocket protocol.
/// The UI (live transcript area, streaming badge) is already wired up
/// and will activate automatically once `isStreaming` becomes true.
///
/// WebSocket Protocol (for future backend implementation):
///   Client → Server:
///     {"type":"transcribe:start","sampleRate":16000,"channels":1,"format":"pcm_s16le"}
///     [binary PCM Int16 LE frames, ~100ms per message]
///     {"type":"transcribe:stop"}
///   Server → Client:
///     {"type":"transcribe:partial","text":"..."}
///     {"type":"transcribe:final","text":"..."}
@Observable
class AudioStreamer: @unchecked Sendable {
    var isStreaming = false
    var liveText = ""

    private weak var webSocket: WebSocketManager?

    /// Call after recording starts. Currently checks if desktop supports streaming.
    func start(webSocket: WebSocketManager) {
        guard !isStreaming, webSocket.isConnected else { return }
        self.webSocket = webSocket
        liveText = ""

        // TODO: Enable when desktop backend supports transcribe:start
        // For now, streaming is not activated — the UI elements
        // (live transcript, streaming badge) remain hidden since isStreaming stays false.
        //
        // To enable in the future:
        // 1. Desktop backend implements WebSocket transcribe protocol
        // 2. Replace this stub with AVAudioEngine-based PCM capture
        // 3. Set isStreaming = true
    }

    func stop() {
        if isStreaming {
            webSocket?.sendJSON(["type": "transcribe:stop"])
        }
        isStreaming = false
        liveText = ""
    }

    func handleEvent(_ event: WebSocketManager.ServerEvent) {
        switch event {
        case .transcribePartial(let text):
            liveText = text
        case .transcribeFinal(let text):
            liveText = text
        default:
            break
        }
    }
}
