import Foundation

/// Times as the session list and the devices screen show them.
enum RelativeTime {
    /// The compact stamp at the end of a session row, the same scale Crok Desktop's sidebar uses:
    /// now, 5m, 3h, 2d, 1w, 2mo, 1y.
    static func compact(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let minutes = Int(seconds / 60)
        if minutes < 1 { return String(localized: "now", comment: "Session row time: less than a minute ago") }
        if minutes < 60 { return String(localized: "\(minutes)m", comment: "Session row time: minutes ago") }
        let hours = minutes / 60
        if hours < 24 { return String(localized: "\(hours)h", comment: "Session row time: hours ago") }
        let days = hours / 24
        if days < 7 { return String(localized: "\(days)d", comment: "Session row time: days ago") }
        if days < 30 { return String(localized: "\(days / 7)w", comment: "Session row time: weeks ago") }
        if days < 365 { return String(localized: "\(days / 30)mo", comment: "Session row time: months ago") }
        return String(localized: "\(days / 365)y", comment: "Session row time: years ago")
    }

    /// "5 minutes ago", localized by the system.
    static func ago(_ date: Date, now: Date, locale: Locale = .current) -> String {
        if now.timeIntervalSince(date) < 60 { return String(localized: "just now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// The Devices screen's status line for a device that is not online.
    static func lastSeen(_ date: Date, now: Date) -> String {
        String(localized: "last seen \(ago(date, now: now))")
    }

    /// Day header text in the transcript: Today, Yesterday, or the date.
    static func dayHeader(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "Today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "Yesterday")
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return sameYear
            ? date.formatted(.dateTime.weekday(.wide).month(.wide).day())
            : date.formatted(.dateTime.year().month(.wide).day())
    }
}
