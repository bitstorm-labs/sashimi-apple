import XCTest
@testable import SashimiMobile

/// `DownloadStatus.paused` was removed (#608): nothing has written it since
/// pause was dropped in #179, but a record stored before then can still say
/// "paused". It must read as something actionable.
final class DownloadStatusMigrationTests: XCTestCase {
    private func record(statusRaw: String) -> DownloadedItem {
        let item = DownloadedItem(
            itemId: "item",
            name: "Episode",
            itemType: .episode,
            quality: .high
        )
        item.statusRaw = statusRaw
        return item
    }

    func testLegacyPausedRecordReadsAsFailedSoItOffersRetry() {
        XCTAssertEqual(record(statusRaw: "paused").status, .failed)
    }

    func testKnownStatusesRoundTrip() {
        for status in [DownloadStatus.queued, .preparing, .downloading, .completed, .failed] {
            XCTAssertEqual(record(statusRaw: status.rawValue).status, status)
        }
    }

    func testUnknownValueKeepsTheQueuedFallback() {
        XCTAssertEqual(record(statusRaw: "something-new").status, .queued)
    }
}
