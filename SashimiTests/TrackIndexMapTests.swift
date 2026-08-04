import XCTest
@testable import Sashimi

/// The off-by-one that plays the commentary track when the user picked
/// Japanese. Jellyfin's global stream index is not the engine's per-category
/// track offset, and the difference depends on delivery and on sidecars.
final class TrackIndexMapTests: XCTestCase {
    private func stream(index: Int, type: String, external: Bool = false) -> MediaStream {
        MediaStream(
            type: type, codec: nil, language: nil, displayTitle: nil, title: nil,
            height: nil, width: nil, channels: nil, index: index,
            isDefault: nil, isExternal: external, isForced: nil,
            videoRangeType: nil, bitRate: nil, deliveryUrl: nil, deliveryMethod: nil
        )
    }

    // A typical MKV: video @0, two embedded audio @1,2, two embedded subs
    // @3,4, and one external sub @5.
    private var mkvStreams: [MediaStream] {
        [
            stream(index: 0, type: "Video"),
            stream(index: 1, type: "Audio"),
            stream(index: 2, type: "Audio"),
            stream(index: 3, type: "Subtitle"),
            stream(index: 4, type: "Subtitle"),
            stream(index: 5, type: "Subtitle", external: true)
        ]
    }

    // MARK: - Direct play

    func testDirectPlayAudioOffsetsAreRankAmongEmbeddedAudio() {
        let map = TrackIndexMap(streams: mkvStreams, delivery: .directPlay)
        XCTAssertEqual(map.audioOffset(forJellyfinIndex: 1), 0)
        XCTAssertEqual(map.audioOffset(forJellyfinIndex: 2), 1)
    }

    func testDirectPlaySubtitleOffsetsExcludeExternal() {
        let map = TrackIndexMap(streams: mkvStreams, delivery: .directPlay)
        XCTAssertEqual(map.subtitleOffset(forJellyfinIndex: 3), 0)
        XCTAssertEqual(map.subtitleOffset(forJellyfinIndex: 4), 1)
        // The external sub is not an embedded track — it has no offset.
        XCTAssertNil(map.subtitleOffset(forJellyfinIndex: 5))
    }

    func testDirectPlayEmbeddedSubtitleCount() {
        let map = TrackIndexMap(streams: mkvStreams, delivery: .directPlay)
        XCTAssertEqual(map.embeddedSubtitleCount, 2)
    }

    func testSidecarLandsAfterEmbeddedSubtitles() {
        let map = TrackIndexMap(streams: mkvStreams, delivery: .directPlay)
        // First sidecar attached goes to offset 2 (after embedded 0,1).
        XCTAssertEqual(map.sidecarSubtitleOffset(attachPosition: 0), 2)
        XCTAssertEqual(map.sidecarSubtitleOffset(attachPosition: 1), 3)
    }

    func testUnknownIndexHasNoOffset() {
        let map = TrackIndexMap(streams: mkvStreams, delivery: .directPlay)
        XCTAssertNil(map.audioOffset(forJellyfinIndex: 99))
        XCTAssertNil(map.subtitleOffset(forJellyfinIndex: 0)) // that's the video stream
    }

    // MARK: - Transcode (HLS)

    func testTranscodeCollapsesAudioToSingleTrack() {
        // The HLS manifest carries exactly one audio track whichever Jellyfin
        // stream produced it, so every audio index maps to offset 0.
        let map = TrackIndexMap(streams: mkvStreams, delivery: .transcode)
        XCTAssertEqual(map.audioOffset(forJellyfinIndex: 1), 0)
        XCTAssertEqual(map.audioOffset(forJellyfinIndex: 2), 0)
    }

    func testTranscodeHasNoEmbeddedSubtitles() {
        let map = TrackIndexMap(streams: mkvStreams, delivery: .transcode)
        XCTAssertEqual(map.embeddedSubtitleCount, 0)
        XCTAssertNil(map.subtitleOffset(forJellyfinIndex: 3))
        // Sidecar still lands at 0 (nothing embedded ahead of it).
        XCTAssertEqual(map.sidecarSubtitleOffset(attachPosition: 0), 0)
    }

    // MARK: - Ordering robustness

    func testOffsetsFollowContainerOrderNotArrayOrder() {
        // Streams delivered out of index order must still map by index.
        let shuffled = [
            stream(index: 2, type: "Audio"),
            stream(index: 0, type: "Video"),
            stream(index: 1, type: "Audio")
        ]
        let map = TrackIndexMap(streams: shuffled, delivery: .directPlay)
        XCTAssertEqual(map.audioOffset(forJellyfinIndex: 1), 0)
        XCTAssertEqual(map.audioOffset(forJellyfinIndex: 2), 1)
    }
}
