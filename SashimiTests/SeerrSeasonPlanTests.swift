import XCTest
@testable import Sashimi

/// The season picker (mockup D): which seasons start ticked, which can't be
/// picked, and what gets sent.
final class SeerrSeasonPlanTests: XCTestCase {
    private let now = SeerrDates.parse("2026-11-06T12:00:00.000Z") ?? Date()

    private func details(
        seasons: [(Int, Int, String?)],
        statuses: [Int: Int] = [:],
        requests: [SeerrRequest]? = nil
    ) throws -> SeerrTitleDetails {
        let seasonJSON = seasons.map { number, episodes, airDate in
            let air = airDate.map { "\"\($0)\"" } ?? "null"
            return "{\"seasonNumber\":\(number),\"episodeCount\":\(episodes),\"airDate\":\(air)}"
        }.joined(separator: ",")
        let statusJSON = statuses.map { "{\"seasonNumber\":\($0.key),\"status\":\($0.value)}" }.joined(separator: ",")
        let json = "{\"id\":1,\"name\":\"Love Is Blind\",\"seasons\":[\(seasonJSON)],\"mediaInfo\":{\"status\":4,\"seasons\":[\(statusJSON)]}}"
        var decoded = try JSONDecoder().decode(SeerrTitleDetails.self, from: Data(json.utf8))
        decoded.mediaInfo?.requests = requests
        return decoded
    }

    private func loveIsBlind() throws -> SeerrTitleDetails {
        var seasons: [(Int, Int, String?)] = [(0, 3, "2020-01-01")]
        seasons += (1...9).map { ($0, 10, "2020-02-13") }
        seasons += [(10, 12, "2026-03-01"), (11, 10, "2026-10-01")]
        let onServer = Dictionary(uniqueKeysWithValues: (1...9).map { ($0, 5) })
        return try details(seasons: seasons, statuses: onServer)
    }

    func testDefaultsToEverySeasonNotOnTheServerAndNeverSpecials() throws {
        let plan = SeerrSeasonPlan(details: try loveIsBlind(), now: now)

        XCTAssertEqual(plan.selected, [10, 11])
        XCTAssertEqual(plan.missing, [10, 11])
        XCTAssertFalse(plan.seasons.contains { $0.number == 0 })
        XCTAssertEqual(plan.requestSeasons, [10, 11])
        XCTAssertEqual(plan.buttonTitle, "Request 2 seasons")
        XCTAssertTrue(plan.allMissingSelected)
    }

    func testSeasonsOnTheServerCollapseIntoOneRowThatCantBePicked() throws {
        let plan = SeerrSeasonPlan(details: try loveIsBlind(), now: now)

        XCTAssertEqual(plan.rows.map(\.title), ["Seasons 1–9", "Season 10", "Season 11"])
        XCTAssertEqual(plan.rows.first?.isPickable, false)
        XCTAssertEqual(plan.rows.first?.detail, "On server")
        XCTAssertEqual(plan.rows[1].detail, "12 episodes")
    }

    func testTogglingAndAllMissing() throws {
        var plan = SeerrSeasonPlan(details: try loveIsBlind(), now: now)

        plan.toggle(11)
        XCTAssertEqual(plan.selected, [10])
        XCTAssertFalse(plan.allMissingSelected)
        XCTAssertEqual(plan.buttonTitle, "Request 1 season")

        plan.toggle(5)
        XCTAssertEqual(plan.selected, [10], "a season on the server can't be ticked")

        plan.setAllMissing(true)
        XCTAssertEqual(plan.selected, [10, 11])
        plan.setAllMissing(false)
        XCTAssertTrue(plan.selected.isEmpty)
        XCTAssertTrue(plan.requestSeasons.isEmpty)
    }

    func testUnairedSeasonsCanBePickedButStartUnticked() throws {
        let plan = SeerrSeasonPlan(
            details: try details(seasons: [(1, 6, "2024-11-17"), (2, 0, nil), (3, 8, "2027-05-01")]),
            now: now
        )

        XCTAssertEqual(plan.selected, [1])
        XCTAssertEqual(plan.rows.map(\.detail), ["6 episodes", "Not aired", "Not aired"])
        XCTAssertTrue(plan.rows[1].isPickable)
        XCTAssertEqual(plan.buttonTitle, "Request 1 season")
    }

    func testSeasonsAlreadyRequestedCantBePickedAgain() throws {
        let pending = SeerrRequest(
            id: 9,
            status: SeerrRequestStatus.pending.rawValue,
            seasons: [SeerrSeasonRequest(seasonNumber: 2, status: 1)]
        )
        let declined = SeerrRequest(
            id: 10,
            status: SeerrRequestStatus.declined.rawValue,
            seasons: [SeerrSeasonRequest(seasonNumber: 3, status: 3)]
        )
        let plan = SeerrSeasonPlan(
            details: try details(
                seasons: [(1, 6, "2020-01-01"), (2, 6, "2021-01-01"), (3, 6, "2022-01-01"), (4, 6, "2023-01-01")],
                statuses: [4: 3],
                requests: [pending, declined]
            ),
            now: now
        )

        XCTAssertEqual(plan.selected, [1, 3], "a declined season can be asked for again")
        XCTAssertEqual(plan.rows.map(\.detail), ["6 episodes", "Requested", "6 episodes", "Requested"])
        XCTAssertFalse(plan.rows[1].isPickable)
    }

    func testWithoutPartialRequestsEveryMissingSeasonGoesTogether() throws {
        var plan = SeerrSeasonPlan(details: try loveIsBlind(), now: now, partialRequestsEnabled: false)

        plan.toggle(10)
        XCTAssertEqual(plan.selected, [10, 11])
        XCTAssertFalse(plan.rows[1].isPickable)
    }

    func testAShowWithEverythingOnTheServerHasNothingMissing() throws {
        let plan = SeerrSeasonPlan(
            details: try details(seasons: [(1, 6, "2020-01-01")], statuses: [1: 5]),
            now: now
        )

        XCTAssertFalse(plan.hasMissingSeasons)
        XCTAssertTrue(plan.selected.isEmpty)
    }
}
