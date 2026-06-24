import Foundation

struct ExtractedItem: Codable, Identifiable {
    let id: Int
    let segmentId: Int?
    let type: String
    let content: String
    let dueDate: String?
    let relatedPerson: String?
    let status: String
    let priority: String?
    let assignee: String?
    // Source attribution — server may populate these so briefing items can
    // jump back to the originating recording / segment timestamp.
    // All optional; nil means we hide the "view source" affordance.
    let recordingId: Int?
    let recordingTitle: String?
    let segmentStartTime: Double?

    enum CodingKeys: String, CodingKey {
        case id, type, content, status, priority, assignee
        case segmentId = "segment_id"
        case dueDate = "due_date"
        case relatedPerson = "related_person"
        case recordingId = "recording_id"
        case recordingTitle = "recording_title"
        case segmentStartTime = "segment_start_time"
    }

    func withStatus(_ newStatus: String) -> ExtractedItem {
        ExtractedItem(
            id: id, segmentId: segmentId, type: type, content: content,
            dueDate: dueDate, relatedPerson: relatedPerson, status: newStatus,
            priority: priority, assignee: assignee,
            recordingId: recordingId, recordingTitle: recordingTitle,
            segmentStartTime: segmentStartTime
        )
    }

    /// True when we know which recording produced this item — UI shows a tap-to-source row.
    var hasSource: Bool { recordingId != nil }

    var isTodo: Bool { type == "todo" }
    var isCompleted: Bool { status == "completed" }

    var typeIcon: String {
        switch type {
        case "todo": "checkmark.circle"
        case "meeting": "calendar"
        case "decision": "hammer.fill"
        case "contact": "person.fill"
        case "number": "number"
        case "memo": "note.text"
        default: "tag"
        }
    }

    var typeColor: String {
        switch type {
        case "todo": "green"
        case "meeting": "blue"
        case "decision": "amber"
        case "contact": "purple"
        case "memo": "teal"
        default: "secondary"
        }
    }
}
