import XCTest
@testable import Sashimi

final class StationRemindersTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func reminder(_ title: String, at date: Date) -> StationReminders.Reminder {
        .init(channelID: "c", channelName: "Unscripted", channelNumber: 3, title: title, startsAt: date)
    }

    func testNothingIsAnnouncedBeforeTheFiveMinuteLead() {
        let r = reminder("Survivor", at: start)
        XCTAssertNil(StationReminders.announcement(in: [r], at: start.addingTimeInterval(-6 * 60), excluding: []))
        XCTAssertEqual(StationReminders.announcement(in: [r], at: start.addingTimeInterval(-5 * 60), excluding: [])?.title, "Survivor")
    }

    func testAnAnnouncementStaysRelevantBrieflyAfterTheStartThenLapses() {
        let r = reminder("Survivor", at: start)
        XCTAssertNotNil(StationReminders.announcement(in: [r], at: start.addingTimeInterval(4 * 60), excluding: []))
        XCTAssertNil(StationReminders.announcement(in: [r], at: start.addingTimeInterval(6 * 60), excluding: []))
    }

    func testEachReminderIsAnnouncedOnceAndTheSoonestComesFirst() {
        let early = reminder("Early", at: start)
        let late = reminder("Late", at: start.addingTimeInterval(120))
        let now = start.addingTimeInterval(-60)
        XCTAssertEqual(StationReminders.announcement(in: [late, early], at: now, excluding: [])?.title, "Early")
        XCTAssertEqual(StationReminders.announcement(in: [late, early], at: now, excluding: [early.id])?.title, "Late")
    }

    @MainActor
    func testTogglingPersistsAndPastRemindersAreDropped() {
        let defaults = UserDefaults(suiteName: "StationRemindersTests.\(UUID().uuidString)")!
        let store = StationReminders(defaults: defaults)
        let r = reminder("Survivor", at: start)
        store.toggle(r)
        XCTAssertTrue(StationReminders(defaults: defaults).isSet(channelID: "c", startsAt: start))

        store.tick(now: start.addingTimeInterval(10 * 60))
        XCTAssertTrue(store.reminders.isEmpty)
        XCTAssertFalse(StationReminders(defaults: defaults).isSet(channelID: "c", startsAt: start))
    }
}
