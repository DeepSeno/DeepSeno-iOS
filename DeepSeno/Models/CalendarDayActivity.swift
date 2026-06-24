import Foundation

/// Per-day activity summary used to render the calendar's "activity dot" cells.
/// The server may expose this directly via `/api/briefing/calendar`; otherwise
/// the client aggregates from `/api/recordings`.
struct CalendarDayActivity: Codable, Hashable {
    /// ISO date "yyyy-MM-dd"
    let date: String
    let recordingCount: Int
    let hasSummary: Bool
    let primaryTopic: String?
    /// First sentence / line of the day's summary, if available.
    let summarySnippet: String?

    enum CodingKeys: String, CodingKey {
        case date
        case recordingCount = "recording_count"
        case hasSummary = "has_summary"
        case primaryTopic = "primary_topic"
        case summarySnippet = "summary_snippet"
    }
}
