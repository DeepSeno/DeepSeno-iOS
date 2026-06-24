import Foundation

/// Format an ISO-8601 timestamp (with or without fractional seconds + TZ) as a
/// short "x minutes/hours/days ago" string. Returns nil if the input can't be
/// parsed — caller should hide the row in that case.
enum RelativeTime {
    private static func iso8601() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    private static func iso8601NoFrac() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }

    static func ago(from iso: String, locale: AppLanguage) -> String? {
        let date = iso8601().date(from: iso) ?? iso8601NoFrac().date(from: iso)
        guard let date else { return nil }
        let seconds = max(0, Date().timeIntervalSince(date))
        let isZh = locale == .zh
        switch seconds {
        case 0..<60:
            return isZh ? "刚刚" : "just now"
        case 60..<3600:
            let m = Int(seconds / 60)
            return isZh ? "\(m) 分钟前" : "\(m)m ago"
        case 3600..<86400:
            let h = Int(seconds / 3600)
            return isZh ? "\(h) 小时前" : "\(h)h ago"
        case 86400..<604800:
            let d = Int(seconds / 86400)
            return isZh ? "\(d) 天前" : "\(d)d ago"
        default:
            let w = Int(seconds / 604800)
            return isZh ? "\(w) 周前" : "\(w)w ago"
        }
    }
}
