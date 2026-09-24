import XCTest
@testable import Sashimi

final class GuideJumpTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Denver")!
        return c
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    func testMiddayOffersNowTonightAndSixDays() {
        let chips = GuideJump.chips(now: date(2026, 9, 24, 13, 26), calendar: calendar)
        XCTAssertEqual(chips.map(\.label), ["Now", "Tonight", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"])
        XCTAssertEqual(chips[1].target, date(2026, 9, 24, 18))
        XCTAssertEqual(chips[2].target, date(2026, 9, 25, 18), "days land on prime time")
    }

    func testAfterPrimeTimeTonightIsGone() {
        // At 20:00 "Tonight" is "Now"; offering both would jump to the same place.
        let chips = GuideJump.chips(now: date(2026, 9, 24, 20), calendar: calendar)
        XCTAssertEqual(chips.map(\.label), ["Now", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"])
    }
}
