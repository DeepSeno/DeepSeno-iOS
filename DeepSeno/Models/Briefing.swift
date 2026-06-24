import Foundation

struct Briefing: Codable {
    let summary: DailySummary?
    let todos: [ExtractedItem]
    let items: [ExtractedItem]
}
