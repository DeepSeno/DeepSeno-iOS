import Foundation

struct DailySummary: Codable {
    let id: Int?
    let date: String
    let summaryText: String?
    let timelineJson: String?
    let keyEventsJson: String?
    /// ISO-8601 timestamp the server generated this briefing. Optional —
    /// older servers don't return it; UI hides the timestamp row in that case.
    let generatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, date
        case summaryText = "summary_text"
        case timelineJson = "timeline_json"
        case keyEventsJson = "key_events_json"
        case generatedAt = "generated_at"
    }
}
