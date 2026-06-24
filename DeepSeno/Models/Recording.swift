import Foundation

struct Recording: Codable, Identifiable, Hashable {
    let id: Int
    let filePath: String
    let fileName: String
    let durationSeconds: Int?
    let recordedAt: String?
    let processedAt: String?
    let status: String
    let mediaType: String
    let pageCount: Int?
    let wordCount: Int?
    let speakerCount: Int?
    let extractedCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, status
        case filePath = "file_path"
        case fileName = "file_name"
        case durationSeconds = "duration_seconds"
        case recordedAt = "recorded_at"
        case processedAt = "processed_at"
        case mediaType = "media_type"
        case pageCount = "page_count"
        case wordCount = "word_count"
        case speakerCount = "speaker_count"
        case extractedCount = "extracted_count"
    }

    var mediaIcon: String {
        switch mediaType {
        case "video": "video.fill"
        case "pdf", "docx", "text": "doc.fill"
        case "image": "photo.fill"
        default: "mic.fill"
        }
    }

    var formattedDuration: String? {
        guard let seconds = durationSeconds else { return nil }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
