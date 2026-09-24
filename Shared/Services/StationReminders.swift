import Foundation
#if os(iOS)
import UserNotifications
#endif

/// "Remind me" for programmes in the SashimiTV guide.
///
/// Kept on the device: a reminder is about this screen in this room, not the
/// account. Five minutes before the programme the app shows a banner; on iOS
/// a local notification is scheduled too, because the app may not be open.
@MainActor
final class StationReminders: ObservableObject {
    static let shared = StationReminders()

    struct Reminder: Codable, Hashable, Identifiable {
        let channelID: String
        let channelName: String
        let channelNumber: Int?
        let title: String
        let startsAt: Date

        var id: String { "\(channelID)-\(Int(startsAt.timeIntervalSince1970))" }
    }

    /// How far ahead of the start the banner appears, and how long after the
    /// start it stays relevant ("is on now").
    static let lead: TimeInterval = 5 * 60
    static let grace: TimeInterval = 5 * 60

    @Published private(set) var reminders: [Reminder]
    /// The reminder being announced, if any.
    @Published private(set) var due: Reminder?

    private let defaults: UserDefaults
    private let key = "stationReminders.v1"
    private var announced: Set<String> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode([Reminder].self, from: data) {
            reminders = saved
        } else {
            reminders = []
        }
    }

    func isSet(channelID: String, startsAt: Date) -> Bool {
        reminders.contains { $0.channelID == channelID && Int($0.startsAt.timeIntervalSince1970) == Int(startsAt.timeIntervalSince1970) }
    }

    func toggle(_ reminder: Reminder) {
        if let index = reminders.firstIndex(where: { $0.id == reminder.id }) {
            reminders.remove(at: index)
            cancelNotification(reminder)
        } else {
            reminders.append(reminder)
            scheduleNotification(reminder)
        }
        save()
    }

    /// Advance the clock: drop reminders long past and pick one to announce.
    func tick(now: Date = Date()) {
        let before = reminders.count
        reminders.removeAll { $0.startsAt.addingTimeInterval(Self.grace) < now }
        if reminders.count != before { save() }

        if let current = due, current.startsAt.addingTimeInterval(Self.grace) < now {
            due = nil
        }
        if due == nil, let next = Self.announcement(in: reminders, at: now, excluding: announced) {
            announced.insert(next.id)
            due = next
        }
    }

    func dismiss() { due = nil }

    /// The reminder to announce now: the soonest one inside its window that has
    /// not been announced yet. Pure, so the timing rules are testable.
    nonisolated static func announcement(in reminders: [Reminder], at now: Date, excluding: Set<String>) -> Reminder? {
        reminders
            .filter { !excluding.contains($0.id) }
            .filter { now >= $0.startsAt.addingTimeInterval(-lead) && now < $0.startsAt.addingTimeInterval(grace) }
            .min { $0.startsAt < $1.startsAt }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(reminders) { defaults.set(data, forKey: key) }
    }

    private func scheduleNotification(_ reminder: Reminder) {
        #if os(iOS)
        let fireAt = reminder.startsAt.addingTimeInterval(-Self.lead)
        guard fireAt > Date() else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            let station = reminder.channelNumber.map { "\($0) · \(reminder.channelName)" } ?? reminder.channelName
            content.body = "Starts at \(reminder.startsAt.formatted(date: .omitted, time: .shortened)) on \(station)."
            content.sound = .default
            content.userInfo = ["stationID": reminder.channelID]
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fireAt)
            let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
            center.add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger))
        }
        #endif
    }

    private func cancelNotification(_ reminder: Reminder) {
        #if os(iOS)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [reminder.id])
        #endif
    }
}
