import Foundation

/// Structured payload the server *may* put inside `WeeklySummary.summaryJson`.
/// If decoding succeeds and at least one section is non-empty, the briefing UI
/// renders rich Themes / People / KeyMoments cards. If decoding fails, the UI
/// falls back to showing `summaryJson` as plain text (legacy behavior).
struct WeeklySummaryStructured: Codable {
    let overview: String?
    let themes: [Theme]?
    let people: [Person]?
    let keyMoments: [KeyMoment]?

    enum CodingKeys: String, CodingKey {
        case overview, themes, people
        case keyMoments = "key_moments"
    }

    struct Theme: Codable, Identifiable {
        let title: String
        let summary: String?
        let recordingIds: [Int]?

        var id: String { title }

        enum CodingKeys: String, CodingKey {
            case title, summary
            case recordingIds = "recording_ids"
        }
    }

    struct Person: Codable, Identifiable {
        let name: String
        let mentionCount: Int?
        let recordingIds: [Int]?

        var id: String { name }

        enum CodingKeys: String, CodingKey {
            case name
            case mentionCount = "mention_count"
            case recordingIds = "recording_ids"
        }
    }

    struct KeyMoment: Codable, Identifiable {
        let recordingId: Int
        let segmentId: Int?
        let summary: String
        let recordingTitle: String?
        let date: String?

        var id: String { "\(recordingId)-\(segmentId ?? 0)" }

        enum CodingKeys: String, CodingKey {
            case recordingId = "recording_id"
            case segmentId = "segment_id"
            case summary
            case recordingTitle = "recording_title"
            case date
        }
    }

    /// True when there's at least one structured section worth rendering.
    var hasContent: Bool {
        let themesOK = !(themes ?? []).isEmpty
        let peopleOK = !(people ?? []).isEmpty
        let momentsOK = !(keyMoments ?? []).isEmpty
        let overviewOK = (overview?.isEmpty == false)
        return themesOK || peopleOK || momentsOK || overviewOK
    }

    /// Try to decode a structured payload from a raw JSON string. Returns nil on
    /// failure or when the result has no usable content (legacy plain-text mode).
    static func tryDecode(from jsonString: String) -> WeeklySummaryStructured? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        guard let decoded = try? JSONDecoder().decode(WeeklySummaryStructured.self, from: data) else {
            return nil
        }
        return decoded.hasContent ? decoded : nil
    }
}
