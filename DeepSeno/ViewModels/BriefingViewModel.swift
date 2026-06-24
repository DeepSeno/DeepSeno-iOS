import SwiftUI

@Observable
class BriefingViewModel: @unchecked Sendable {
    enum ViewMode: String, CaseIterable {
        case daily = "Daily"
        case weekly = "Weekly"
    }

    var mode: ViewMode = .daily
    var selectedDate: Date = Date()
    var dailySummary: DailySummary?
    var weeklySummary: WeeklySummary?
    var todos: [ExtractedItem] = []
    var items: [ExtractedItem] = []
    var isLoading: Bool = false
    var isRegenerating: Bool = false
    var errorMessage: String?
    /// Calendar dot data keyed by yyyy-MM-dd. Loaded lazily per displayed month.
    var calendarActivity: [String: CalendarDayActivity] = [:]
    private var loadedMonths: Set<String> = []

    // MARK: - Computed

    /// API-facing date string (server expects ISO yyyy-MM-dd, locale-independent).
    var dateString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: selectedDate)
    }

    /// User-visible "May 16, 2026" (EN) / "2026年5月16日" (ZH).
    var displayDate: String {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.current.locale
        if mode == .daily {
            formatter.dateStyle = .long
        } else {
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
        }
        return formatter.string(from: selectedDate)
    }

    var weekStartDate: Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: selectedDate)
        return calendar.date(from: components) ?? selectedDate
    }

    /// "May 11 - May 17" (EN) / "5月11日 - 5月17日" (ZH).
    var weekDisplayRange: String {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.current.locale
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        let start = weekStartDate
        let end = Calendar.current.date(byAdding: .day, value: 6, to: start) ?? start
        return "\(formatter.string(from: start)) - \(formatter.string(from: end))"
    }

    // MARK: - Navigation

    func previousDate() {
        if mode == .daily {
            selectedDate = Calendar.current.date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate
        } else {
            selectedDate = Calendar.current.date(byAdding: .weekOfYear, value: -1, to: selectedDate) ?? selectedDate
        }
    }

    func nextDate() {
        if mode == .daily {
            selectedDate = Calendar.current.date(byAdding: .day, value: 1, to: selectedDate) ?? selectedDate
        } else {
            selectedDate = Calendar.current.date(byAdding: .weekOfYear, value: 1, to: selectedDate) ?? selectedDate
        }
    }

    // MARK: - Loading

    func loadData(apiClient: APIClient) async {
        if mode == .daily {
            await loadDaily(apiClient: apiClient)
        } else {
            await loadWeekly(apiClient: apiClient)
        }
    }

    func loadDaily(apiClient: APIClient) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let briefing = try await apiClient.getBriefing(date: dateString)
            dailySummary = briefing.summary
            todos = briefing.todos
            items = briefing.items
        } catch {
            // Fallback: try individual endpoints
            do {
                dailySummary = try await apiClient.getDailySummary(date: dateString)
            } catch {
                dailySummary = nil
            }
            do {
                todos = try await apiClient.getExtractedItems(type: "todo")
            } catch {
                todos = []
            }
            do {
                items = try await apiClient.getExtractedItems()
                items = items.filter { !$0.isTodo }
            } catch {
                items = []
            }
        }
    }

    func loadWeekly(apiClient: APIClient) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let startStr = formatter.string(from: weekStartDate)

        do {
            weeklySummary = try await apiClient.getWeeklySummary(startDate: startStr)
        } catch {
            weeklySummary = nil
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Calendar Activity

    /// Fetch per-day activity for the displayed month. Tries the server endpoint
    /// first; falls back to client-side aggregation from the recordings list if
    /// the server doesn't expose `/api/briefing/calendar` yet.
    func loadCalendarActivity(forMonthContaining date: Date, apiClient: APIClient) async {
        let cal = Calendar(identifier: .gregorian)
        guard let startOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: date)),
              let endOfMonth = cal.date(byAdding: DateComponents(month: 1, day: -1), to: startOfMonth)
        else { return }

        let monthKey = isoDate(startOfMonth)
        guard !loadedMonths.contains(monthKey) else { return }
        loadedMonths.insert(monthKey)

        let startStr = isoDate(startOfMonth)
        let endStr = isoDate(endOfMonth)

        // Try the dedicated endpoint first.
        if let serverActivities = try? await apiClient.getCalendarActivity(start: startStr, end: endStr) {
            for a in serverActivities { calendarActivity[a.date] = a }
            return
        }

        // Fallback: aggregate from /api/recordings. Group by recordedAt date.
        do {
            let all = try await apiClient.getRecordings()
            let byDate = Dictionary(grouping: all) { rec -> String in
                guard let recordedAt = rec.recordedAt,
                      let isoDate = isoDateFromTimestamp(recordedAt) else { return "" }
                return isoDate
            }
            for (date, recordings) in byDate where !date.isEmpty {
                // Only count days within the requested month
                guard date >= startStr && date <= endStr else { continue }
                let count = recordings.count
                calendarActivity[date] = CalendarDayActivity(
                    date: date,
                    recordingCount: count,
                    hasSummary: false,
                    primaryTopic: nil,
                    summarySnippet: nil
                )
            }
        } catch {
            // Network error — just skip; calendar shows no dots, no harm done.
            loadedMonths.remove(monthKey)
        }
    }

    private func isoDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Parse a server timestamp ("yyyy-MM-dd HH:mm:ss" or ISO-8601) and return
    /// just the date portion. Used for fallback aggregation.
    private func isoDateFromTimestamp(_ ts: String) -> String? {
        // Server format guess: take first 10 chars if they parse as yyyy-MM-dd
        let head = String(ts.prefix(10))
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        return parser.date(from: head) != nil ? head : nil
    }

    // MARK: - Regenerate

    /// Trigger server-side regeneration of the current daily / weekly summary
    /// and reload. Server can take 10–30s (LLM call).
    func regenerate(apiClient: APIClient) async {
        guard !isRegenerating else { return }
        isRegenerating = true
        errorMessage = nil
        defer { isRegenerating = false }
        let isWeekly = mode == .weekly
        let modeStr = isWeekly ? "weekly" : "daily"
        let dateForServer = isWeekly ? isoDate(weekStartDate) : dateString
        do {
            try await apiClient.regenerateBriefing(mode: modeStr, date: dateForServer)
            await loadData(apiClient: apiClient)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Todos

    func toggleTodo(id: Int, currentStatus: String, apiClient: APIClient) async {
        let newStatus = currentStatus == "completed" ? "active" : "completed"

        // Optimistic local update — no full page reload
        if let idx = todos.firstIndex(where: { $0.id == id }) {
            todos[idx] = todos[idx].withStatus(newStatus)
        }

        do {
            try await apiClient.updateItemStatus(id: id, status: newStatus)
        } catch {
            // Revert on failure
            if let idx = todos.firstIndex(where: { $0.id == id }) {
                todos[idx] = todos[idx].withStatus(currentStatus)
            }
            errorMessage = error.localizedDescription
        }
    }
}
