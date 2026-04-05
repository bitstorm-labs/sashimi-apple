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
