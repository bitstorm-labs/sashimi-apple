import XCTest
@testable import Sashimi

/// What each title and request shows: the poster pill in search, the state
/// of a row in Your requests, and which requests earn the Home row.
final class SeerrStatusTests: XCTestCase {
    private func info(_ status: Int?, requests: [SeerrRequest]? = nil) -> SeerrMediaInfo {
        SeerrMediaInfo(status: status, requests: requests)
    }

    private func request(
        id: Int = 1,
        status: SeerrRequestStatus,
        by user: Int = 7,
        media: SeerrMediaInfo? = nil,
        kind: SeerrMediaKind = .movie,
        seasons: [Int]? = nil,
        created: String = "2026-11-06T09:00:00.000Z",
        updated: String? = nil
    ) -> SeerrRequest {
        SeerrRequest(
            id: id,
            status: status.rawValue,
            type: kind,
            createdAt: created,
            updatedAt: updated ?? created,
            seasons: seasons?.map { SeerrSeasonRequest(seasonNumber: $0, status: status.rawValue) },
            media: media,
            requestedBy: SeerrRequestUser(id: user)
        )
    }

    // MARK: Search pill

    func testNothingKnownIsRequestable() {
        XCTAssertEqual(SeerrBadge(mediaInfo: nil, userId: 7), .request)
        XCTAssertEqual(SeerrBadge(mediaInfo: info(1), userId: 7), .request)
    }

    func testPendingProcessingAndAvailableMapToTheirPills() {
        XCTAssertEqual(SeerrBadge(mediaInfo: info(2), userId: 7), .pending)
        XCTAssertEqual(SeerrBadge(mediaInfo: info(3), userId: 7), .coming)
        XCTAssertEqual(SeerrBadge(mediaInfo: info(5), userId: 7), .available)
    }

    func testPartiallyAvailableCanStillBeRequested() {
        XCTAssertEqual(SeerrBadge(mediaInfo: info(4), userId: 7), .request)
    }

    func testBlocklistedAndDeletedReadAsUnknown() {
        XCTAssertEqual(SeerrBadge(mediaInfo: info(6), userId: 7), .request)
        XCTAssertEqual(SeerrBadge(mediaInfo: info(7), userId: 7), .request)
    }

    func testMyDeclinedRequestShowsDeclined() {
        let declined = info(1, requests: [request(status: .declined)])
        XCTAssertEqual(SeerrBadge(mediaInfo: declined, userId: 7), .declined)
    }

    func testSomeoneElsesDeclinedRequestDoesNotStopMe() {
        let declined = info(1, requests: [request(status: .declined, by: 99)])
        XCTAssertEqual(SeerrBadge(mediaInfo: declined, userId: 7), .request)
    }

    func testPillLabelsMatchTheMockups() {
        XCTAssertEqual(SeerrBadge.request.label, "Request")
        XCTAssertEqual(SeerrBadge.pending.label, "Pending")
        XCTAssertEqual(SeerrBadge.coming.label, "Coming")
        XCTAssertEqual(SeerrBadge.declined.label, "Declined")
    }

    // MARK: Your requests

    func testRequestStates() {
        XCTAssertEqual(SeerrRequestState(request(status: .pending, media: info(2))), .pending)
        XCTAssertEqual(SeerrRequestState(request(status: .declined, media: info(1))), .declined)
        XCTAssertEqual(SeerrRequestState(request(status: .approved, media: info(3))), .coming(progress: nil))
        XCTAssertEqual(SeerrRequestState(request(status: .approved, media: info(5))), .ready)
        XCTAssertEqual(SeerrRequestState(request(status: .completed, media: info(5))), .ready)
        XCTAssertEqual(SeerrRequestState(request(status: .failed, media: info(3))), .failed)
    }

    func testDownloadProgressAddsUpEveryDownload() {
        var media = info(3)
        media.downloadStatus = [SeerrDownload(size: 100, sizeLeft: 50), SeerrDownload(size: 300, sizeLeft: 102)]
        guard case .coming(let progress?) = SeerrRequestState(request(status: .approved, media: media)) else {
            return XCTFail("expected progress")
        }
        XCTAssertEqual(progress, 0.62, accuracy: 0.001)
    }

    func testAShowIsReadyOnlyWhenEveryRequestedSeasonIsOnTheServer() {
        var media = info(4)
        media.seasons = [SeerrSeasonStatus(seasonNumber: 1, status: 5), SeerrSeasonStatus(seasonNumber: 2, status: 3)]
        let both = request(status: .approved, media: media, kind: .tv, seasons: [1, 2])
        let first = request(status: .approved, media: media, kind: .tv, seasons: [1])

        XCTAssertEqual(SeerrRequestState(both), .coming(progress: nil))
        XCTAssertEqual(SeerrRequestState(first), .ready)
    }

    func testSubtitlesReadLikeTheMockup() throws {
        let now = try XCTUnwrap(SeerrDates.parse("2026-11-06T18:00:00.000Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))

        var downloading = info(3)
        downloading.downloadStatus = [SeerrDownload(size: 100, sizeLeft: 38)]
        var arrived = info(5)
        arrived.mediaAddedAt = "2026-11-05T20:00:00.000Z"

        let pending = request(status: .pending, created: "2026-11-06T09:00:00.000Z")
        let approved = request(status: .approved, media: downloading, created: "2026-11-02T09:00:00.000Z", updated: "2026-11-03T09:00:00.000Z")
        let ready = request(status: .approved, media: arrived, created: "2026-10-30T09:00:00.000Z")
        let declined = request(status: .declined, created: "2026-10-01T09:00:00.000Z")

        XCTAssertEqual(SeerrRequestState.subtitle(for: pending, now: now, calendar: calendar), "Requested today")
        XCTAssertEqual(SeerrRequestState.subtitle(for: approved, now: now, calendar: calendar), "Approved Tue · 62% downloaded")
        XCTAssertEqual(SeerrRequestState.subtitle(for: ready, now: now, calendar: calendar), "Arrived yesterday")
        XCTAssertEqual(SeerrRequestState.subtitle(for: declined, now: now, calendar: calendar), "Requested Oct 1")
    }

    func testHomeRowShowsWaitingRequestsAndLastWeeksArrivalsOnly() throws {
        let now = try XCTUnwrap(SeerrDates.parse("2026-11-06T18:00:00.000Z"))
        var recent = info(5)
        recent.mediaAddedAt = "2026-11-02T10:00:00.000Z"
        var old = info(5)
        old.mediaAddedAt = "2026-10-20T10:00:00.000Z"

        XCTAssertTrue(SeerrRequestState.showsOnHome(request(status: .pending), now: now))
        XCTAssertTrue(SeerrRequestState.showsOnHome(request(status: .approved, media: info(3)), now: now))
        XCTAssertTrue(SeerrRequestState.showsOnHome(request(status: .approved, media: recent), now: now))
        XCTAssertFalse(SeerrRequestState.showsOnHome(request(status: .approved, media: old), now: now))
        XCTAssertFalse(SeerrRequestState.showsOnHome(request(status: .declined), now: now))
    }

    // MARK: TMDB show status

    func testTmdbShowStatusesMapToTheSeriesBadge() {
        XCTAssertEqual(SeriesStatus(tmdbStatus: "Returning Series"), .continuing)
        XCTAssertEqual(SeriesStatus(tmdbStatus: "In Production"), .continuing)
        XCTAssertEqual(SeriesStatus(tmdbStatus: "Ended"), .ended)
        XCTAssertEqual(SeriesStatus(tmdbStatus: "Canceled"), .ended)
        XCTAssertEqual(SeriesStatus(tmdbStatus: "Planned"), .upcoming)
        XCTAssertNil(SeriesStatus(tmdbStatus: nil))
    }
}
