import Foundation

struct WeeklySummary: Codable {
    let id: Int?
    let startDate: String
    let endDate: String
    let summaryJson: String?
    /// ISO-8601 timestamp the server generated this weekly digest. Optional.
    let generatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case startDate = "start_date"
        case endDate = "end_date"
        case summaryJson = "summary_json"
        case generatedAt = "generated_at"
    }
}
