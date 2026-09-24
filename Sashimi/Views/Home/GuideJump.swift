import Foundation

/// The places a viewer can jump to in a week of guide: now, tonight, and the
/// next six days at prime time. Pure so the calendar rules can be tested.
struct GuideJump: Identifiable, Equatable {
    enum Kind: Equatable { case now, tonight, day }

    let kind: Kind
    let label: String
    /// Rows jump to the first programme still airing at this instant.
    let target: Date

    var id: String { label }

    static let primeTimeHour = 18

    static func chips(now: Date, calendar: Calendar = .current) -> [GuideJump] {
        var chips = [GuideJump(kind: .now, label: "Now", target: now)]

        let today = calendar.startOfDay(for: now)
        if let tonight = calendar.date(byAdding: .hour, value: primeTimeHour, to: today), tonight > now {
            // "Tonight" only while it is still ahead; after 18:00 it is "Now".
            chips.append(GuideJump(kind: .tonight, label: "Tonight", target: tonight))
        }

        let weekday = DateFormatter()
        weekday.calendar = calendar
        weekday.dateFormat = "EEE"
        for offset in 1...6 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let prime = calendar.date(byAdding: .hour, value: primeTimeHour, to: day) else { continue }
            chips.append(GuideJump(kind: .day, label: weekday.string(from: prime), target: prime))
        }
        return chips
    }
}
