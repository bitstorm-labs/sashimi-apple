import XCTest
@testable import SashimiMobile

final class DownloadRetryPolicyTests: XCTestCase {
    private typealias Policy = DownloadRetryPolicy

    private var suiteName = ""
    private var defaults = UserDefaults.standard
    private let now = Date(timeIntervalSince1970: 1_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "DownloadRetryPolicyTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private static func urlError(_ code: Int) -> NSError {
        NSError(domain: NSURLErrorDomain, code: code)
    }

    // MARK: - Schedule

    func testBackoffIsOneFiveThirtyMinutesThenStops() {
        XCTAssertEqual(Policy.delay(afterFailure: 1), 60)
        XCTAssertEqual(Policy.delay(afterFailure: 2), 5 * 60)
        XCTAssertEqual(Policy.delay(afterFailure: 3), 30 * 60)
        XCTAssertNil(Policy.delay(afterFailure: 4))
        XCTAssertNil(Policy.delay(afterFailure: 0))
    }

    // MARK: - Classification

    func testClientErrorsArePermanent() {
        for code in [400, 401, 403, 404, 410] {
            XCTAssertEqual(Policy.classify(httpStatusCode: code), .permanent, "HTTP \(code)")
        }
    }

    func testServerErrorsTimeoutsAndRateLimitsAreTransient() {
        for code in [408, 429, 500, 502, 503, 504] {
            XCTAssertEqual(Policy.classify(httpStatusCode: code), .transient, "HTTP \(code)")
        }
    }

    func testNetworkErrorsAreTransient() {
        let codes = [
            NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet,
            NSURLErrorCannotConnectToHost, NSURLErrorBackgroundSessionWasDisconnected
        ]
        for code in codes {
            XCTAssertEqual(Policy.classify(error: Self.urlError(code)), .transient, "code \(code)")
        }
    }

    func testCertificateAuthAndDiskErrorsArePermanent() {
        XCTAssertEqual(Policy.classify(error: Self.urlError(NSURLErrorServerCertificateUntrusted)), .permanent)
        XCTAssertEqual(Policy.classify(error: Self.urlError(NSURLErrorUserAuthenticationRequired)), .permanent)
        XCTAssertEqual(Policy.classify(error: Self.urlError(NSURLErrorCannotWriteToFile)), .permanent)
        let outOfSpace = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        XCTAssertEqual(Policy.classify(error: outOfSpace), .permanent)
    }

    func testJellyfinErrorsFollowTheirStatus() {
        XCTAssertEqual(Policy.classify(error: JellyfinError.httpError(statusCode: 404)), .permanent)
        XCTAssertEqual(Policy.classify(error: JellyfinError.httpError(statusCode: 503)), .transient)
        XCTAssertEqual(Policy.classify(error: JellyfinError.sessionExpired), .permanent)
        XCTAssertEqual(Policy.classify(error: JellyfinError.notConfigured), .permanent)
        XCTAssertEqual(Policy.classify(error: JellyfinError.networkError(Self.urlError(NSURLErrorTimedOut))), .transient)
    }

    // MARK: - Store

    func testTransientFailuresWalkTheScheduleAndThenStop() {
        let store = DownloadRetryStore(defaults: defaults)
        let first = store.recordFailure(itemId: "ep1", serverID: "s1", kind: .transient, now: now)
        XCTAssertEqual(first?.failures, 1)
        XCTAssertEqual(first?.nextRetryAt, now.addingTimeInterval(60))

        store.recordFailure(itemId: "ep1", serverID: "s1", kind: .transient, now: now)
        let third = store.recordFailure(itemId: "ep1", serverID: "s1", kind: .transient, now: now)
        XCTAssertEqual(third?.nextRetryAt, now.addingTimeInterval(30 * 60))

        let fourth = store.recordFailure(itemId: "ep1", serverID: "s1", kind: .transient, now: now)
        XCTAssertEqual(fourth?.failures, 4)
        XCTAssertNil(fourth?.nextRetryAt, "after three retries it stays failed for a manual retry")
        XCTAssertTrue(store.due(at: now.addingTimeInterval(86_400)).isEmpty)
    }

    func testCountSurvivesARelaunch() {
        let store = DownloadRetryStore(defaults: defaults)
        store.recordFailure(itemId: "ep1", serverID: "s1", kind: .transient, now: now)
        store.recordFailure(itemId: "ep1", serverID: "s1", kind: .transient, now: now)

        let relaunched = DownloadRetryStore(defaults: defaults)
        XCTAssertEqual(relaunched.entry(itemId: "ep1", serverID: "s1")?.failures, 2)
        let next = relaunched.recordFailure(itemId: "ep1", serverID: "s1", kind: .transient, now: now)
        XCTAssertEqual(next?.failures, 3, "a relaunch must not reset the count into an endless loop")
    }

    func testPermanentFailureSchedulesNothing() {
        let store = DownloadRetryStore(defaults: defaults)
        store.recordFailure(itemId: "ep1", serverID: "s1", kind: .transient, now: now)
        XCTAssertNil(store.recordFailure(itemId: "ep1", serverID: "s1", kind: .permanent, now: now))
        XCTAssertNil(store.entry(itemId: "ep1", serverID: "s1"))
        XCTAssertTrue(store.due(at: now.addingTimeInterval(86_400)).isEmpty)
    }

    func testDueAndNextRetryDate() {
        let store = DownloadRetryStore(defaults: defaults)
        store.recordFailure(itemId: "a", serverID: "s1", kind: .transient, now: now) // due at +1 min
        store.recordFailure(itemId: "b", serverID: "s1", kind: .transient, now: now)
        store.recordFailure(itemId: "b", serverID: "s1", kind: .transient, now: now) // due at +5 min

        XCTAssertTrue(store.due(at: now).isEmpty)
        XCTAssertEqual(store.nextRetryDate(after: now), now.addingTimeInterval(60))
        XCTAssertEqual(store.due(at: now.addingTimeInterval(61)).map(\.itemId), ["a"])
        XCTAssertEqual(store.nextRetryDate(after: now.addingTimeInterval(61)), now.addingTimeInterval(300))
    }

    func testEntriesAreKeyedByServerAndItem() {
        let store = DownloadRetryStore(defaults: defaults)
        store.recordFailure(itemId: "ep1", serverID: "s1", kind: .transient, now: now)
        XCTAssertNil(store.entry(itemId: "ep1", serverID: "s2"))
        store.clear(itemId: "ep1", serverID: "s2")
        XCTAssertNotNil(store.entry(itemId: "ep1", serverID: "s1"))
        store.clear(itemId: "ep1", serverID: "s1")
        XCTAssertNil(DownloadRetryStore(defaults: defaults).entry(itemId: "ep1", serverID: "s1"))
    }

    // MARK: - Row label

    func testLabelCountsDownInWholeMinutes() {
        XCTAssertEqual(Policy.label(nextRetryAt: now.addingTimeInterval(300), now: now, waitReason: nil), "Retrying in 5 min")
        XCTAssertEqual(Policy.label(nextRetryAt: now.addingTimeInterval(241), now: now, waitReason: nil), "Retrying in 5 min")
        XCTAssertEqual(Policy.label(nextRetryAt: now.addingTimeInterval(20), now: now, waitReason: nil), "Retrying in 1 min")
    }

    func testDueRetryHeldBackByTheNetworkSaysWhy() {
        XCTAssertEqual(Policy.label(nextRetryAt: now, now: now, waitReason: .cellular), "Will retry on Wi-Fi")
        XCTAssertEqual(Policy.label(nextRetryAt: now, now: now, waitReason: .offline), "Will retry when online")
    }
}
