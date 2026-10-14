import XCTest
@testable import Sashimi

final class SeriesStatusTests: XCTestCase {
    private func item(_ json: String) throws -> BaseItemDto {
        try JSONDecoder().decode(BaseItemDto.self, from: Data(json.utf8))
    }

    func testASeriesShowsItsStatus() throws {
        XCTAssertEqual(SeriesStatus(item: try item(#"{"Id":"s","Name":"S","Type":"Series","Status":"Continuing"}"#)), .continuing)
        XCTAssertEqual(SeriesStatus(item: try item(#"{"Id":"s","Name":"S","Type":"Series","Status":"Ended"}"#)), .ended)
        XCTAssertEqual(SeriesStatus(item: try item(#"{"Id":"s","Name":"S","Type":"Series","Status":"Unreleased"}"#)), .upcoming)
    }

    func testTheLabelsAreWhatTheUserReads() {
        XCTAssertEqual(SeriesStatus.continuing.label, "Continuing")
        XCTAssertEqual(SeriesStatus.ended.label, "Ended")
        XCTAssertEqual(SeriesStatus.upcoming.label, "Upcoming")
    }

    func testNoBadgeWithoutAKnownStatus() throws {
        XCTAssertNil(SeriesStatus(item: try item(#"{"Id":"s","Name":"S","Type":"Series"}"#)))
        XCTAssertNil(SeriesStatus(item: try item(#"{"Id":"s","Name":"S","Type":"Series","Status":"Something"}"#)))
    }

    func testSeasonsAndEpisodesShowTheirShowsStatus() throws {
        let episode = try item(#"{"Id":"e","Name":"E","Type":"Episode","SeriesId":"s"}"#)
        let season = try item(#"{"Id":"z","Name":"Z","Type":"Season","SeriesId":"s"}"#)
        XCTAssertEqual(SeriesStatus(item: episode, seriesStatus: "Continuing"), .continuing)
        XCTAssertEqual(SeriesStatus(item: season, seriesStatus: "Ended"), .ended)
        XCTAssertNil(SeriesStatus(item: episode), "no badge until the show's status is known")
    }

    func testAShowUsesItsOwnStatusNotTheOneItIsHanded() throws {
        let show = try item(#"{"Id":"s","Name":"S","Type":"Series","Status":"Ended"}"#)
        XCTAssertEqual(SeriesStatus(item: show, seriesStatus: "Continuing"), .ended)
    }

    func testMoviesNeverGetOne() throws {
        XCTAssertNil(SeriesStatus(item: try item(#"{"Id":"m","Name":"M","Type":"Movie","Status":"Ended"}"#), seriesStatus: "Ended"))
    }
}
