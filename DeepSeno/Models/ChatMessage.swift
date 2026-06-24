import Foundation

struct ChatMessage: Codable, Identifiable {
    let id: Int
    let sessionId: Int?
    let role: String
    let content: String
    let sourcesJson: String?
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, role, content
        case sessionId = "session_id"
        case sourcesJson = "sources_json"
        case createdAt = "created_at"
    }

    var isUser: Bool { role == "user" }
    var isAssistant: Bool { role == "assistant" }
}

struct StreamingMessage: Identifiable {
    let id = UUID()
    var role: String
    var content: String
    var isStreaming: Bool
    var sources: [Source]

    struct Source: Codable {
        let segmentId: Int?
        let recordingId: Int?
        let speaker: String?
        let text: String?
        let time: String?

        enum CodingKeys: String, CodingKey {
            case segmentId = "segment_id"
            case recordingId = "recording_id"
            case speaker, text, time
        }
    }
}
