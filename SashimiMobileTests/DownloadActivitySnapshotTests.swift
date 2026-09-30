import XCTest
@testable import SashimiMobile

final class DownloadActivitySnapshotTests: XCTestCase {
    func testIdleWhenNothingIsActiveOrQueued() {
        let snapshot = DownloadActivitySnapshot(active: [:], preparingKeys: [], queuedCount: 0)

        XCTAssertFalse(snapshot.isActive)
        XCTAssertEqual(snapshot, .idle)
    }

    func testCountUnionsActiveAndPreparingAndAddsQueued() {
        // A task waiting for its first bytes is in both sets; count it once.
        let snapshot = DownloadActivitySnapshot(
            active: ["s:a": DownloadItemProgress(fraction: 0)],
            preparingKeys: ["s:a"],
            queuedCount: 5
        )

        XCTAssertEqual(snapshot.activeCount, 6)
        XCTAssertTrue(snapshot.isActive)
    }

    func testQueuedOnlyIsActiveWithUnknownProgress() {
        let snapshot = DownloadActivitySnapshot(active: [:], preparingKeys: ["s:a"], queuedCount: 2)

        XCTAssertEqual(snapshot.activeCount, 3)
        XCTAssertNil(snapshot.progress)
    }

    func testProgressIsTotalBytesWhenEverySizeIsKnown() throws {
        // Byte-weighted, not averaged: (100 + 900) / (1_000 + 1_000) = 0.5,
        // where the mean of fractions would be 0.55.
        let progress = DownloadActivitySnapshot.overallProgress([
            DownloadItemProgress(fraction: 0.1, bytesWritten: 100, bytesExpected: 1_000),
            DownloadItemProgress(fraction: 1.0, bytesWritten: 900, bytesExpected: 1_000),
        ])

        XCTAssertEqual(try XCTUnwrap(progress), 0.5, accuracy: 0.0001)
    }

    func testProgressAveragesKnownFractionsWhenAnySizeIsUnknown() throws {
        let progress = DownloadActivitySnapshot.overallProgress([
            DownloadItemProgress(fraction: 0.2, bytesWritten: 200, bytesExpected: 1_000),
            DownloadItemProgress(fraction: 0.6),
            DownloadItemProgress(fraction: -1, bytesWritten: 5_000, bytesExpected: -1),
        ])

        XCTAssertEqual(try XCTUnwrap(progress), 0.4, accuracy: 0.0001)
    }

    func testProgressIsUnknownWhenNoItemReportsOne() {
        XCTAssertNil(DownloadActivitySnapshot.overallProgress([]))
        XCTAssertNil(DownloadActivitySnapshot.overallProgress([
            DownloadItemProgress(fraction: -1, bytesWritten: 10, bytesExpected: -1),
        ]))
    }

    func testProgressIsClampedToOne() throws {
        let progress = DownloadActivitySnapshot.overallProgress([
            DownloadItemProgress(fraction: 1, bytesWritten: 1_200, bytesExpected: 1_000),
        ])

        XCTAssertEqual(try XCTUnwrap(progress), 1)
    }
}
