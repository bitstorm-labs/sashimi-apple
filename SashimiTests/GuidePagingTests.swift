import XCTest
@testable import Sashimi

final class GuidePagingTests: XCTestCase {
    func testAnEmptyRowStillHasOnePage() {
        XCTAssertEqual(GuidePaging.pageCount(0), 1)
        XCTAssertTrue(GuidePaging.visible([Int](), page: 0).isEmpty)
        XCTAssertFalse(GuidePaging.hasMore(0, page: 0))
    }

    func testPagesDealThreeAtATime() {
        let items = Array(1...7)
        XCTAssertEqual(GuidePaging.pageCount(items.count), 3)
        XCTAssertEqual(Array(GuidePaging.visible(items, page: 0)), [1, 2, 3])
        XCTAssertEqual(Array(GuidePaging.visible(items, page: 1)), [4, 5, 6])
        XCTAssertEqual(Array(GuidePaging.visible(items, page: 2)), [7])
    }

    func testHasMoreStopsOnTheLastPage() {
        XCTAssertTrue(GuidePaging.hasMore(7, page: 0))
        XCTAssertTrue(GuidePaging.hasMore(7, page: 1))
        XCTAssertFalse(GuidePaging.hasMore(7, page: 2))
        XCTAssertFalse(GuidePaging.hasMore(3, page: 0))
    }

    func testARememberedPageThatNoLongerExistsIsClampedNotEmpty() {
        // The guide refreshes every minute and rows shrink as programmes air.
        let items = Array(1...4)
        XCTAssertEqual(GuidePaging.clamp(page: 9, count: items.count), 1)
        XCTAssertEqual(Array(GuidePaging.visible(items, page: 9)), [4])
        XCTAssertEqual(GuidePaging.clamp(page: -3, count: items.count), 0)
    }
}
