import Foundation
import SwiftData

@Observable
class CacheManager: @unchecked Sendable {
    private var modelContext: ModelContext?
    var isSyncing: Bool = false

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }

    // MARK: - Sync on Connect

    func syncOnConnect(apiClient: APIClient) async {
        guard modelContext != nil else { return }
        isSyncing = true
        defer { isSyncing = false }

        // Sync recordings (last 30)
        await syncRecordings(apiClient: apiClient)

        // Sync briefings (last 7 days)
        await syncBriefings(apiClient: apiClient)

        // Clean old cache
        clearOldCache()
    }

    private func syncRecordings(apiClient: APIClient) async {
        do {
            let recordings = try await apiClient.getRecordings()
            let recent = Array(recordings.prefix(30))

            for recording in recent {
                upsertRecording(recording)
            }
            try? modelContext?.save()
        } catch {
            // Silently fail — cache is best-effort
        }
    }

    private func syncBriefings(apiClient: APIClient) async {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let calendar = Calendar.current

        for dayOffset in 0..<7 {
            guard let date = calendar.date(byAdding: .day, value: -dayOffset, to: Date()) else {
                continue
            }
            let dateStr = formatter.string(from: date)

            do {
                let briefing = try await apiClient.getBriefing(date: dateStr)
                upsertBriefing(dateStr: dateStr, briefing: briefing)
            } catch {
                // Skip this date
            }
        }
        try? modelContext?.save()
    }

    // MARK: - Upsert

    private func upsertRecording(_ recording: Recording) {
        guard let context = modelContext else { return }
        let recordingId = recording.id

        let descriptor = FetchDescriptor<CachedRecording>(
            predicate: #Predicate { $0.recordingId == recordingId }
        )

        if let existing = try? context.fetch(descriptor).first {
            existing.fileName = recording.fileName
            existing.mediaType = recording.mediaType
            existing.status = recording.status
            existing.dateString = recording.recordedAt ?? ""
            existing.durationSeconds = recording.durationSeconds
            existing.cachedAt = Date()
        } else {
            let cached = CachedRecording(from: recording)
            context.insert(cached)
        }
    }

    private func upsertBriefing(dateStr: String, briefing: Briefing) {
        guard let context = modelContext else { return }

        let descriptor = FetchDescriptor<CachedBriefing>(
            predicate: #Predicate { $0.dateString == dateStr }
        )

        let todosData = try? JSONEncoder().encode(briefing.todos)
        let itemsData = try? JSONEncoder().encode(briefing.items)

        if let existing = try? context.fetch(descriptor).first {
            existing.summaryText = briefing.summary?.summaryText
            existing.todosJson = todosData.flatMap { String(data: $0, encoding: .utf8) }
            existing.itemsJson = itemsData.flatMap { String(data: $0, encoding: .utf8) }
            existing.cachedAt = Date()
        } else {
            let cached = CachedBriefing(
                dateString: dateStr,
                summaryText: briefing.summary?.summaryText,
                todosJson: todosData.flatMap { String(data: $0, encoding: .utf8) },
                itemsJson: itemsData.flatMap { String(data: $0, encoding: .utf8) }
            )
            context.insert(cached)
        }
    }

    // MARK: - Read Cache

    func getCachedRecordings() -> [CachedRecording] {
        guard let context = modelContext else { return [] }
        let descriptor = FetchDescriptor<CachedRecording>(
            sortBy: [SortDescriptor(\.cachedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func getCachedBriefing(date: String) -> CachedBriefing? {
        guard let context = modelContext else { return nil }
        let descriptor = FetchDescriptor<CachedBriefing>(
            predicate: #Predicate { $0.dateString == date }
        )
        return try? context.fetch(descriptor).first
    }

    // MARK: - Cleanup

    func clearOldCache() {
        guard let context = modelContext else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()

        let recordingDescriptor = FetchDescriptor<CachedRecording>(
            predicate: #Predicate { $0.cachedAt < cutoff }
        )
        let briefingDescriptor = FetchDescriptor<CachedBriefing>(
            predicate: #Predicate { $0.cachedAt < cutoff }
        )

        if let old = try? context.fetch(recordingDescriptor) {
            for item in old { context.delete(item) }
        }
        if let old = try? context.fetch(briefingDescriptor) {
            for item in old { context.delete(item) }
        }
        try? context.save()
    }
}
