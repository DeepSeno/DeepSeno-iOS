import Foundation

struct MeetingNotes: Codable {
    let title: String?
    let participants: [Participant]?
    let decisions: [String]?
    let actionItems: [ActionItem]?
    let discussionSummary: String?
    let keyTopics: [String]?

    enum CodingKeys: String, CodingKey {
        case title, participants, decisions
        case actionItems = "action_items"
        case discussionSummary = "discussion_summary"
        case keyTopics = "key_topics"
    }

    struct Participant: Codable {
        let name: String
        let speakingTime: Double?

        enum CodingKeys: String, CodingKey {
            case name
            case speakingTime = "speaking_time"
        }
    }

    struct ActionItem: Codable {
        let assignee: String?
        let task: String
        let dueDate: String?

        enum CodingKeys: String, CodingKey {
            case assignee, task
            case dueDate = "due_date"
        }
    }
}
