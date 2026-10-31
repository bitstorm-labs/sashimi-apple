import XCTest
@testable import SashimiMobile

/// Image-based subtitle tracks (PGS, VobSub, DVB) have no VTT form: asking the
/// server for one returns 500, and the per-launch backfill asked again every
/// launch (#824). Downloads fetch text tracks only.
final class DownloadSubtitleSelectionTests: XCTestCase {
    private func stream(codec: String, index: Int, language: String? = "eng") -> MediaStream {
        MediaStream(
            type: "Subtitle", codec: codec, language: language, displayTitle: nil,
            title: nil, height: nil, width: nil, channels: nil, index: index, isDefault: nil,
            isExternal: false, isForced: nil, videoRangeType: nil, bitRate: nil,
            deliveryUrl: nil, deliveryMethod: nil
        )
    }

    func testImageBasedTracksAreNotFetched() {
        let streams = [
            stream(codec: "subrip", index: 3),
            stream(codec: "PGSSUB", index: 4),
            stream(codec: "dvd_subtitle", index: 5),
            stream(codec: "dvb_subtitle", index: 6),
            stream(codec: "xsub", index: 7),
            stream(codec: "ass", index: 8)
        ]
        let fetched = DownloadManager.subtitleStreamsToFetch(streams, skipping: [])
        XCTAssertEqual(fetched.compactMap(\.index), [3, 8])
    }

    func testTheMontoCristoTrackListFetchesOnlyTheSRT() {
        // The Count of Monte Cristo (2024): one SRT, three PGS tracks.
        let streams = [
            stream(codec: "subrip", index: 3),
            stream(codec: "PGSSUB", index: 4),
            stream(codec: "PGSSUB", index: 5),
            stream(codec: "PGSSUB", index: 6, language: "fra")
        ]
        XCTAssertEqual(DownloadManager.subtitleStreamsToFetch(streams, skipping: []).compactMap(\.index), [3])
        // Once the SRT is on disk the backfill has nothing left to ask for.
        XCTAssertTrue(DownloadManager.subtitleStreamsToFetch(streams, skipping: [3]).isEmpty)
    }

    func testTracksOnDiskOrWithoutANameAreSkipped() {
        let streams = [
            stream(codec: "subrip", index: 3),
            stream(codec: "subrip", index: 4, language: nil),
            stream(codec: "webvtt", index: 5)
        ]
        XCTAssertEqual(DownloadManager.subtitleStreamsToFetch(streams, skipping: [5]).compactMap(\.index), [3])
    }
}
