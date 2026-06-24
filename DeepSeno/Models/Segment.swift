import Foundation

struct Segment: Codable, Identifiable {
    let id: Int
    let recordingId: Int
    let speakerId: Int?
    let startTime: Double?
    let endTime: Double?
    let rawText: String?
    let cleanText: String?
    let createdAt: String
    let speakerName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case recordingId = "recording_id"
        case speakerId = "speaker_id"
        case startTime = "start_time"
        case endTime = "end_time"
        case rawText = "raw_text"
        case cleanText = "clean_text"
        case createdAt = "created_at"
        case speakerName = "speaker_name"
    }

    var displayText: String {
        cleanText ?? rawText ?? ""
    }

    var formattedTime: String? {
        guard let start = startTime else { return nil }
        let m = Int(start) / 60
        let s = Int(start) % 60
        return String(format: "%d:%02d", m, s)
    }
}
