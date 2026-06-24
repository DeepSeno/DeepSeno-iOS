import Foundation
import SwiftData

@Model
class CaptureItem {
    var id: UUID
    var type: String          // "audio", "photo", "text", "file"
    var localPath: String
    var fileName: String
    var textContent: String?  // for text memos
    var groupPaths: String?   // JSON array of file paths for multi-image groups
    var groupName: String?    // group identifier for multi-image upload
    var bookmarksJSON: String? // JSON array of bookmark timestamps in ms
    var createdAt: Date
    var retries: Int
    var status: String        // "pending", "uploading", "failed"

    init(type: String, localPath: String, fileName: String, textContent: String? = nil) {
        self.id = UUID()
        self.type = type
        self.localPath = localPath
        self.fileName = fileName
        self.textContent = textContent
        self.createdAt = Date()
        self.retries = 0
        self.status = "pending"
    }
}
