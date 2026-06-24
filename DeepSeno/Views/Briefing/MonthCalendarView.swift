import SwiftUI

/// Apple-Calendar-style month grid with per-day activity indicators.
///
/// Replaces `DatePicker(.graphical)` so we can render an activity dot under each
/// day (server-driven via `getCalendarActivity` or client-aggregated from the
/// recordings list as fallback). Long-press a day to peek at its summary.
struct MonthCalendarView: View {
    @Binding var selectedDate: Date
    /// Keyed by yyyy-MM-dd → activity. Days without entries get no dot.
    let activities: [String: CalendarDayActivity]
    let locale: Locale
    /// Caller is told when the displayed month changes so it can refetch
    /// activity for the new range.
    var onDisplayedMonthChange: ((Date) -> Void)? = nil

    @State private var displayedMonth: Date
    @State private var peekActivity: CalendarDayActivity?
    @State private var peekDayId: String?

    init(
        selectedDate: Binding<Date>,
        activities: [String: CalendarDayActivity],
        locale: Locale,
        onDisplayedMonthChange: ((Date) -> Void)? = nil
    ) {
        self._selectedDate = selectedDate
        self.activities = activities
        self.locale = locale
        self.onDisplayedMonthChange = onDisplayedMonthChange
        // Initial month = month of selected date
        let cal = Self.makeCalendar(locale: locale)
        _displayedMonth = State(initialValue: cal.startOfMonth(for: selectedDate.wrappedValue))
    }

    var body: some View {
        VStack(spacing: 8) {
            monthHeader
            weekdayHeader
            daysGrid
        }
    }

    private var calendar: Calendar { Self.makeCalendar(locale: locale) }

    private static func makeCalendar(locale: Locale) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = locale
        cal.firstWeekday = locale.identifier.hasPrefix("zh") ? 2 /* Mon */ : 1 /* Sun */
        return cal
    }

    // MARK: - Header

    private var monthHeader: some View {
        HStack {
            Button {
                if let prev = calendar.date(byAdding: .month, value: -1, to: displayedMonth) {
                    displayedMonth = prev
                    onDisplayedMonthChange?(prev)
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DeepSenoTheme.textSecondary)
                    .frame(width: 32, height: 32)
            }

            Spacer()

            Text(monthTitle)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(DeepSenoTheme.textPrimary)

            Spacer()

            Button {
                if let next = calendar.date(byAdding: .month, value: 1, to: displayedMonth) {
                    // Never advance past the current month (no data in the future)
                    if next <= calendar.startOfMonth(for: Date()) {
                        displayedMonth = next
                        onDisplayedMonthChange?(next)
                    }
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(
                        canGoForward
                            ? DeepSenoTheme.textSecondary
                            : DeepSenoTheme.textTertiary.opacity(0.3)
                    )
                    .frame(width: 32, height: 32)
            }
            .disabled(!canGoForward)
        }
        .padding(.horizontal, 4)
    }

    private var monthTitle: String {
        let f = DateFormatter()
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate("yMMMM")
        return f.string(from: displayedMonth)
    }

    private var canGoForward: Bool {
        guard let next = calendar.date(byAdding: .month, value: 1, to: displayedMonth) else { return false }
        return next <= calendar.startOfMonth(for: Date())
    }

    // MARK: - Weekday header

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(weekdaySymbols, id: \.self) { day in
                Text(day)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DeepSenoTheme.textTertiary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var weekdaySymbols: [String] {
        let f = DateFormatter()
        f.locale = locale
        let symbols = f.veryShortStandaloneWeekdaySymbols ?? f.veryShortWeekdaySymbols ?? []
        // Reorder so the locale's firstWeekday comes first.
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    // MARK: - Days grid

    private var daysGrid: some View {
        let days = monthDays
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 4) {
            ForEach(days, id: \.id) { cell in
                dayCell(cell)
            }
        }
    }

    @ViewBuilder
    private func dayCell(_ cell: DayCell) -> some View {
        let isSelected = calendar.isDate(cell.date, inSameDayAs: selectedDate)
        let isToday = calendar.isDateInToday(cell.date)
        let inMonth = cell.inDisplayedMonth
        let activity = activities[cell.iso]
        let isFuture = cell.date > Date()

        VStack(spacing: 2) {
            ZStack {
                if isSelected {
                    Circle().fill(DeepSenoTheme.accentGreen)
                } else if isToday {
                    Circle().stroke(DeepSenoTheme.accentGreen.opacity(0.6), lineWidth: 1)
                }
                Text("\(cell.dayNumber)")
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(
                        isSelected
                            ? .white
                            : inMonth
                                ? DeepSenoTheme.textPrimary
                                : DeepSenoTheme.textTertiary.opacity(0.4)
                    )
            }
            .frame(width: 32, height: 32)

            // Activity dot — opacity scales with recording count (capped at 5)
            if let activity, activity.recordingCount > 0 {
                let intensity = min(Double(activity.recordingCount) / 5.0, 1.0)
                Circle()
                    .fill(DeepSenoTheme.accentGreen.opacity(0.4 + intensity * 0.6))
                    .frame(width: 5, height: 5)
            } else {
                // Reserve vertical space so days without dots don't shift up
                Circle().fill(Color.clear).frame(width: 5, height: 5)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isFuture else { return }
            selectedDate = cell.date
        }
        .onLongPressGesture(minimumDuration: 0.4) {
            guard let activity, activity.recordingCount > 0 || activity.hasSummary else { return }
            peekActivity = activity
            peekDayId = cell.iso
        }
        .opacity(isFuture && inMonth ? 0.35 : 1.0)
        .popover(isPresented: Binding(
            get: { peekDayId == cell.iso && peekActivity != nil },
            set: { if !$0 { peekActivity = nil; peekDayId = nil } }
        )) {
            if let a = peekActivity {
                ActivityPeekCard(activity: a, locale: locale)
                    .presentationCompactAdaptation(.popover)
            }
        }
    }

    // MARK: - Date math

    private struct DayCell: Hashable {
        let date: Date
        let dayNumber: Int
        let inDisplayedMonth: Bool
        let iso: String
        var id: String { iso }
    }

    private var monthDays: [DayCell] {
        let cal = calendar
        let startOfMonth = cal.startOfMonth(for: displayedMonth)
        guard let monthRange = cal.range(of: .day, in: .month, for: displayedMonth) else { return [] }

        // Leading days from previous month so the first row aligns to firstWeekday.
        let firstWeekdayInMonth = cal.component(.weekday, from: startOfMonth)
        let leadingCount = (firstWeekdayInMonth - cal.firstWeekday + 7) % 7

        let isoFormatter = DateFormatter()
        isoFormatter.locale = Locale(identifier: "en_US_POSIX")
        isoFormatter.dateFormat = "yyyy-MM-dd"

        var cells: [DayCell] = []

        // Previous-month leading days
        for offset in stride(from: leadingCount, to: 0, by: -1) {
            if let d = cal.date(byAdding: .day, value: -offset, to: startOfMonth) {
                cells.append(DayCell(
                    date: d,
                    dayNumber: cal.component(.day, from: d),
                    inDisplayedMonth: false,
                    iso: isoFormatter.string(from: d)
                ))
            }
        }
        // Current-month days
        for day in 1...monthRange.count {
            if let d = cal.date(byAdding: .day, value: day - 1, to: startOfMonth) {
                cells.append(DayCell(
                    date: d,
                    dayNumber: day,
                    inDisplayedMonth: true,
                    iso: isoFormatter.string(from: d)
                ))
            }
        }
        // Trailing days to complete the last row (always 6 rows = 42 cells for stable height)
        while cells.count % 7 != 0 || cells.count < 42 {
            if let last = cells.last, let d = cal.date(byAdding: .day, value: 1, to: last.date) {
                cells.append(DayCell(
                    date: d,
                    dayNumber: cal.component(.day, from: d),
                    inDisplayedMonth: false,
                    iso: isoFormatter.string(from: d)
                ))
            } else {
                break
            }
        }
        return cells
    }
}

private extension Calendar {
    func startOfMonth(for date: Date) -> Date {
        self.date(from: self.dateComponents([.year, .month], from: date)) ?? date
    }
}

/// Compact card shown when the user long-presses a calendar day with activity.
private struct ActivityPeekCard: View {
    let activity: CalendarDayActivity
    let locale: Locale

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(formattedDate)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(DeepSenoTheme.accentGreen)

            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.system(size: 10))
                Text("\(activity.recordingCount)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                if let topic = activity.primaryTopic, !topic.isEmpty {
                    Text("· \(topic)")
                        .font(.system(size: 12))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(DeepSenoTheme.textSecondary)

            if let snippet = activity.summarySnippet, !snippet.isEmpty {
                Text(snippet)
                    .font(.system(size: 12))
                    .foregroundStyle(DeepSenoTheme.textPrimary)
                    .lineLimit(3)
            }
        }
        .padding(12)
        .frame(maxWidth: 240, alignment: .leading)
        .background(DeepSenoTheme.bgSecondary)
    }

    private var formattedDate: String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: activity.date) else { return activity.date }
        let f = DateFormatter()
        f.locale = locale
        f.dateStyle = .medium
        return f.string(from: date)
    }
}
