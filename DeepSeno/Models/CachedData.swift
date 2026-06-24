import Foundation
import SwiftData

@Model
class CachedRecording {
    var recordingId: Int
    var fileName: String
    var mediaType: String
    var status: String
    var dateString: String
    var summary: String?
    var durationSeconds: Int?
    var cachedAt: Date

    init(from recording: Recording) {
        self.recordingId = recording.id
        self.fileName = recording.fileName
        self.mediaType = recording.mediaType
        self.status = recording.status
        self.dateString = recording.recordedAt ?? ""
        self.summary = nil
        self.durationSeconds = recording.durationSeconds
        self.cachedAt = Date()
    }

    init(recordingId: Int, fileName: String, mediaType: String, status: String,
         dateString: String, summary: String? = nil, durationSeconds: Int? = nil) {
        self.recordingId = recordingId
        self.fileName = fileName
        self.mediaType = mediaType
        self.status = status
        self.dateString = dateString
        self.summary = summary
        self.durationSeconds = durationSeconds
        self.cachedAt = Date()
    }
}

@Model
class CachedBriefing {
    var dateString: String
    var summaryText: String?
    var todosJson: String?
    var itemsJson: String?
    var cachedAt: Date

    init(dateString: String, summaryText: String? = nil,
         todosJson: String? = nil, itemsJson: String? = nil) {
        self.dateString = dateString
        self.summaryText = summaryText
        self.todosJson = todosJson
        self.itemsJson = itemsJson
        self.cachedAt = Date()
    }
}
