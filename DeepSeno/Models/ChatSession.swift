import Foundation

struct ChatSession: Codable, Identifiable {
    let id: Int
    let title: String
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, title
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
