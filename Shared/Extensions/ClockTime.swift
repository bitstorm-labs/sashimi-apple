import Foundation

/// Clock times as the app's 24-Hour Time setting asks for them: "15:51" or
/// "3:51 PM". The player's clock and "Finishes at" always honoured it; the
/// SashimiTV guide, station bar and reminders used the system format instead.
enum ClockTime {
    /// The `PlaybackSettings.use24HourTime` key. Read straight from defaults
    /// rather than through `PlaybackSettings`, which is main-actor bound, so a
    /// notification body built off the main thread can use it too.
    static let settingKey = "use24HourTime"

    enum Style: Equatable {
        case twelveHour, twentyFourHour
        /// The device's own format.
        case system

        init(use24Hour: Bool) { self = use24Hour ? .twentyFourHour : .twelveHour }
    }

    /// The setting. tvOS has a toggle whose default (off) the player clock has
    /// always followed, so tvOS always answers. iPhone and iPad have no toggle,
    /// so there an unset value keeps the system's own format instead of
    /// forcing 12-hour on a 24-hour locale.
    static func preference(_ defaults: UserDefaults = .standard) -> Style {
        #if os(tvOS)
        return Style(use24Hour: defaults.bool(forKey: settingKey))
        #else
        guard defaults.object(forKey: settingKey) != nil else { return .system }
        return Style(use24Hour: defaults.bool(forKey: settingKey))
        #endif
    }

    private static func pattern(_ style: Style) -> String {
        style == .twentyFourHour ? "HH:mm" : "h:mm a"
    }

    /// "15:51" / "3:51 PM".
    static func time(_ date: Date, style: Style = preference()) -> String {
        guard style != .system else { return date.formatted(date: .omitted, time: .shortened) }
        return formatter(pattern(style)).string(from: date)
    }

    /// "Sat 15:51" / "Saturday 3:51 PM" — a guide week makes a bare time ambiguous.
    static func weekdayTime(_ date: Date, wide: Bool = false, style: Style = preference()) -> String {
        guard style != .system else {
            return date.formatted(.dateTime.weekday(wide ? .wide : .abbreviated).hour().minute())
        }
        let day = wide ? "EEEE" : "EEE"
        return formatter("\(day) \(pattern(style))").string(from: date)
    }

    /// "Sep 25, 2026 at 15:51" — the guide's header clock.
    static func dateTime(_ date: Date, style: Style = preference()) -> String {
        guard style != .system else { return date.formatted(date: .abbreviated, time: .shortened) }
        return "\(date.formatted(date: .abbreviated, time: .omitted)) at \(time(date, style: style))"
    }

    // Guide cells format on every render; build each pattern's formatter once.
    private static let formatters: [String: DateFormatter] = {
        // A locale rebuilt from its identifier, not `.current`: the current
        // locale carries the device's own 12/24-hour switch, which silently
        // rewrites a fixed "h:mm a" to "15:51" (and "HH:mm" the other way), so
        // the setting lost to the device. Language and AM/PM symbols stay.
        let locale = Locale(identifier: Locale.current.identifier)
        var out: [String: DateFormatter] = [:]
        for pattern in ["HH:mm", "h:mm a", "EEE HH:mm", "EEE h:mm a", "EEEE HH:mm", "EEEE h:mm a"] {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.dateFormat = pattern
            out[pattern] = formatter
        }
        return out
    }()

    private static func formatter(_ pattern: String) -> DateFormatter {
        formatters[pattern] ?? DateFormatter()
    }
}
