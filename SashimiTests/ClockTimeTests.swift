import XCTest
@testable import Sashimi

final class ClockTimeTests: XCTestCase {
    /// 15:51 on a Saturday, local time — the formatters use the device zone.
    private let date: Date = {
        var parts = DateComponents()
        (parts.year, parts.month, parts.day, parts.hour, parts.minute) = (2026, 9, 26, 15, 51)
        return Calendar.current.date(from: parts)!
    }()

    func testTwentyFourHour() {
        XCTAssertEqual(ClockTime.time(date, style: .twentyFourHour), "15:51")
        XCTAssertEqual(ClockTime.weekdayTime(date, style: .twentyFourHour).suffix(6), " 15:51")
        XCTAssertTrue(ClockTime.dateTime(date, style: .twentyFourHour).hasSuffix(" at 15:51"))
    }

    func testTwelveHour() {
        let time = ClockTime.time(date, style: .twelveHour)
        XCTAssertTrue(time.hasPrefix("3:51"), time)
        XCTAssertFalse(time.contains("15"), time)
        XCTAssertFalse(ClockTime.weekdayTime(date, wide: true, style: .twelveHour).contains("15:"))
    }

    func testTVOSFollowsTheToggleAndItsDefault() {
        let defaults = UserDefaults(suiteName: "ClockTimeTests")!
        defaults.removePersistentDomain(forName: "ClockTimeTests")
        // Unset: the toggle's default, off — what the player clock always showed.
        XCTAssertEqual(ClockTime.preference(defaults), .twelveHour)
        defaults.set(true, forKey: ClockTime.settingKey)
        XCTAssertEqual(ClockTime.preference(defaults), .twentyFourHour)
        defaults.removePersistentDomain(forName: "ClockTimeTests")
    }
}
