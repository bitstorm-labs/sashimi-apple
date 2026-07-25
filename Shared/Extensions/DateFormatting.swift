import Foundation

// Shared date and runtime formatting utilities.
// Replaces duplicated formatDate/formatRuntime across 5+ files.

enum DateFormatting {
    private static let isoFormatterFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoFormatterStandard: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let longDisplayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter
    }()

    private static let shortNumericFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M-d-yyyy"
        return formatter
    }()

    /// Long form, e.g. "May 7, 2026". Callers used to build two
    /// ISO8601DateFormatters plus a DateFormatter inline, inside computed
    /// properties — so three expensive allocations on every body evaluation, per
    /// card. All four sites now share these cached instances.
    static func formatLongDate(_ isoString: String?) -> String? {
        guard let date = parseDate(isoString) else { return nil }
        return longDisplayFormatter.string(from: date)
    }

    private static let mediumDisplayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()

    /// Abbreviated form, e.g. "May 7, 2026" -> "May 7, 2026" with a short month.
    static func formatMediumDate(_ isoString: String?) -> String? {
        guard let date = parseDate(isoString) else { return nil }
        return mediumDisplayFormatter.string(from: date)
    }

    /// Compact numeric form, e.g. "5-7-2026".
    static func formatShortNumericDate(_ isoString: String?) -> String? {
        guard let date = parseDate(isoString) else { return nil }
        return shortNumericFormatter.string(from: date)
    }

    /// Parse an ISO8601 date string (with or without fractional seconds) and return a display string.
    static func formatDate(_ isoString: String?) -> String? {
        guard let isoString else { return nil }

        let date = isoFormatterFractional.date(from: isoString)
            ?? isoFormatterStandard.date(from: isoString)

        guard let date else { return nil }
        return displayFormatter.string(from: date)
    }

    /// Parse an ISO8601 date string to a Date object.
    static func parseDate(_ isoString: String?) -> Date? {
        guard let isoString else { return nil }
        return isoFormatterFractional.date(from: isoString)
            ?? isoFormatterStandard.date(from: isoString)
    }

    /// Format runtime ticks (10,000 ticks = 1ms) to "Xh Ym" or "Xm".
    static func formatRuntime(_ ticks: Int64?) -> String? {
        guard let ticks, ticks > 0 else { return nil }
        let totalMinutes = Int(ticks / 600_000_000)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    /// Format remaining ticks as "Xh Ym left" or "Xm left".
    static func formatRemainingTime(_ ticks: Int64) -> String? {
        guard ticks > 0 else { return nil }
        let totalMinutes = Int(ticks / 600_000_000)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m left"
        }
        return "\(minutes)m left"
    }
}
