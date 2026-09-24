import XCTest
@testable import Sashimi

final class GuidePagingTests: XCTestCase {
    func testAnEmptyRowShowsNothingAndHasNoMore() {
        XCTAssertTrue(GuidePaging.visible([Int](), offset: 0).isEmpty)
        XCTAssertFalse(GuidePaging.hasMore(0, offset: 0))
        XCTAssertEqual(GuidePaging.clamp(offset: 5, count: 0), 0)
    }

    func testThreeCardsFromAnyOffset() {
        let items = Array(1...7)
        XCTAssertEqual(Array(GuidePaging.visible(items, offset: 0)), [1, 2, 3])
        XCTAssertEqual(Array(GuidePaging.visible(items, offset: 4)), [5, 6, 7])
        XCTAssertEqual(Array(GuidePaging.visible(items, offset: 6)), [7], "a jump can land anywhere, not only on a multiple of three")
    }

    func testPagingMovesByThreeAndStopsAtTheEnds() {
        XCTAssertEqual(GuidePaging.next(offset: 0, count: 7), 3)
        XCTAssertEqual(GuidePaging.next(offset: 3, count: 7), 6)
        XCTAssertEqual(GuidePaging.next(offset: 6, count: 7), 6)
        XCTAssertEqual(GuidePaging.previous(offset: 1, count: 7), 0)
        XCTAssertTrue(GuidePaging.hasMore(7, offset: 0))
        XCTAssertFalse(GuidePaging.hasMore(7, offset: 4), "the last card is already showing")
    }

    func testARememberedOffsetThatNoLongerExistsIsClampedNotEmpty() {
        // The guide refreshes and rows shrink as programmes air.
        let items = Array(1...4)
        XCTAssertEqual(GuidePaging.clamp(offset: 9, count: items.count), 3)
        XCTAssertEqual(Array(GuidePaging.visible(items, offset: 9)), [4])
    }
}
