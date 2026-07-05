import Foundation

struct PingResponse: Codable {
    let name: String
    let version: String
    let platform: String
}

struct UploadResponse: Codable {
    let success: Bool
    let filePath: String?
    let taskId: String?
}

struct QueryResponse: Codable {
    let answer: String?
    let sources: [StreamingMessage.Source]?
}

struct ConnectionInfo: Codable {
    let host: String
    let port: Int
    let token: String
    let fingerprint: String?

    /// Relay info — if present, the QR code supports encrypted relay through the server.
    let relay: RelayInfo?

    struct RelayInfo: Codable {
        let mid: String   // desktop machineId for relay routing
        let pub: String   // desktop's ECDH P-256 public key (base64 SPKI DER)
        let nonce: String // pairing nonce (base64)
    }
}

struct SearchResult: Codable, Identifiable {
    let id: Int
    let recordingId: Int
    let cleanText: String?
    let rawText: String?
    let speakerName: String?
    let recordingName: String?
    let startTime: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case recordingId = "recording_id"
        case cleanText = "clean_text"
        case rawText = "raw_text"
        case speakerName = "speaker_name"
        case recordingName = "recording_name"
        case startTime = "start_time"
    }

    var displayText: String { cleanText ?? rawText ?? "" }
}
