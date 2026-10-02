import XCTest
@testable import SashimiMobile

final class DownloadWatchStateCacheTests: XCTestCase {
    func testCacheWrittenBeforeRatingsStillDecodes() throws {
        let legacy = Data(#"{"played":true,"positionTicks":42}"#.utf8)
        let state = try JSONDecoder().decode(ServerWatchState.self, from: legacy)
        XCTAssertTrue(state.played)
        XCTAssertEqual(state.positionTicks, 42)
        XCTAssertNil(state.communityRating)
    }

    func testRatingRoundTripsThroughTheCache() throws {
        let state = ServerWatchState(played: false, positionTicks: 0, communityRating: 7.6)
        let decoded = try JSONDecoder().decode(ServerWatchState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.communityRating, 7.6)
    }
}
