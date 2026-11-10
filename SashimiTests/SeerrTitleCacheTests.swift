import XCTest
@testable import Sashimi

/// Callers that fill one cache at the same time (Discover's sliders do).
@MainActor
final class SeerrTitleCacheTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SeerrStubServer.reset()
        SeerrClient.testURLProtocolClasses = [SeerrStubServer.self]
    }

    override func tearDown() {
        SeerrClient.testURLProtocolClasses = []
        super.tearDown()
    }

    private func target(_ id: Int) -> SeerrTarget { SeerrTarget(kind: .movie, tmdbId: id, title: "") }

    func testTwoFillsOverlappingOnATitleBothSeeItAndItIsFetchedOnce() async {
        for id in 1...3 {
            SeerrStubServer.on("GET", "/api/v1/movie/\(id)", body: "{\"id\":\(id),\"title\":\"T\(id)\",\"mediaInfo\":{\"status\":2}}")
        }
        SeerrStubServer.detailsDelay = 0.1
        let client = SeerrClient(baseURL: SeerrFixtures.server, cookie: nil)
        let cache = SeerrTitleCache()

        /// What the caller sees the moment its own fill returns.
        func filled(_ targets: [SeerrTarget], limit: Int?) async -> String? {
            if let limit { await cache.fill(targets, client: client, maxConcurrent: limit) } else { await cache.fill(targets, client: client) }
            return cache.entry(for: target(2))?.title
        }
        let first = Task { await filled([target(1), target(2)], limit: nil) }
        while SeerrStubServer.requests.isEmpty { await Task.yield() } // the first fill's fetches are under way
        let seenBySecond = await filled([target(2)], limit: 2)
        let seenByFirst = await first.value

        XCTAssertEqual(seenByFirst, "T2", "the caller that started the fetch sees it")
        XCTAssertEqual(seenBySecond, "T2", "the caller that joined it sees it too when it returns")
        XCTAssertEqual(cache.entry(for: target(1))?.title, "T1")
        XCTAssertEqual(SeerrStubServer.requests("GET", "/api/v1/movie/2").count, 1)
    }

    func testAFillLeavesOutATitleThatFailsAndTriesItAgainNextTime() async {
        SeerrStubServer.on("GET", "/api/v1/movie/1", status: 500, body: "{}")
        let client = SeerrClient(baseURL: SeerrFixtures.server, cookie: nil)
        let cache = SeerrTitleCache()

        await cache.fill([target(1)], client: client, maxConcurrent: 4)
        XCTAssertNil(cache.entry(for: target(1)))
        await cache.fill([target(1)], client: client, maxConcurrent: 4)

        XCTAssertEqual(SeerrStubServer.requests("GET", "/api/v1/movie/1").count, 2)
    }
}
