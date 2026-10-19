import AVFoundation
import XCTest
@testable import Sashimi

/// Which audio tracks SpatialAudioBridge plays as APAC in place of the
/// server's audio.
final class SpatialAudioSelectionTests: XCTestCase {
    /// An MKV remux as Jellyfin's PlaybackInfo describes it: an external
    /// track listed first, then TrueHD Atmos, plain TrueHD, DTS:X and plain
    /// DTS-HD MA inside the file.
    private func source(
        container: String = "mkv",
        transcodeReasons: String? = "ContainerNotSupported,AudioCodecNotSupported"
    ) throws -> MediaSourceInfo {
        let reasons = transcodeReasons.map { "&TranscodeReasons=\($0)" } ?? ""
        let json = """
        {
          "Id": "source-1", "Container": "\(container)", "DefaultAudioStreamIndex": 2,
          "TranscodingUrl": "/videos/x/master.m3u8?AudioStreamIndex=2&ApiKey=key\(reasons)",
          "MediaStreams": [
            { "Type": "Video", "Index": 0, "Codec": "hevc" },
            { "Type": "Audio", "Index": 1, "Codec": "aac", "IsExternal": true },
            { "Type": "Audio", "Index": 2, "Codec": "truehd", "Profile": "Dolby TrueHD + Dolby Atmos" },
            { "Type": "Audio", "Index": 3, "Codec": "truehd" },
            { "Type": "Audio", "Index": 4, "Codec": "dts", "Profile": "DTS-HD MA + DTS:X" },
            { "Type": "Audio", "Index": 5, "Codec": "dts", "Profile": "DTS-HD MA" }
          ]
        }
        """
        return try JSONDecoder().decode(MediaSourceInfo.self, from: Data(json.utf8))
    }

    private func position(
        in source: MediaSourceInfo,
        audio: Int?,
        subtitle: Int = StreamTrackRequest.noSubtitle
    ) -> Int? {
        PlaybackSelection.spatialAudioTrackPosition(
            in: source,
            tracks: StreamTrackRequest(mediaSourceId: source.id, audioStreamIndex: audio, subtitleStreamIndex: subtitle)
        )
    }

    func testAtmosAndDTSXPlayAtTheirPlaceAmongTheFilesTracks() throws {
        let source = try source()
        // The external track is not in the file, so TrueHD Atmos is its first.
        XCTAssertEqual(position(in: source, audio: 2), 0)
        XCTAssertEqual(position(in: source, audio: 4), 2)
        // No pick: the server's default stream plays.
        XCTAssertEqual(position(in: source, audio: nil), 0)
    }

    func testOtherTracksKeepTheServersAudio() throws {
        let source = try source()
        XCTAssertNil(position(in: source, audio: 1), "external")
        XCTAssertNil(position(in: source, audio: 3), "plain TrueHD")
        XCTAssertNil(position(in: source, audio: 5), "plain DTS-HD MA")
    }

    func testOnlyAMatroskaFileWithCopiedVideoQualifies() throws {
        XCTAssertNil(position(in: try source(transcodeReasons: "AudioCodecNotSupported,ContainerBitrateExceedsLimit"), audio: 2))
        XCTAssertNil(position(in: try source(transcodeReasons: nil), audio: 2), "video copy unknown")
        XCTAssertNil(position(in: try source(), audio: 2, subtitle: 6), "burned-in subtitle")
        XCTAssertNil(position(in: try source(container: "mp4"), audio: 2))
    }
}

/// What a rebuild after a failure remembers about the spatial audio stream.
@MainActor
final class SpatialAudioRecoveryTests: XCTestCase {
    private final class FakeStream: SpatialAudioPlaying {
        let playlistURL = URL(fileURLWithPath: "/nonexistent/master.m3u8")
        let trackKey = "source-1/0"
        let failed: Bool
        var stopped = false
        init(failed: Bool) { self.failed = failed }
        var hasFailed: Bool { get async { failed } }
        func attach(to player: AVPlayer) {}
        func stop() { stopped = true }
    }

    private func recover(from stream: FakeStream) async -> PlayerViewModel {
        let item = BaseItemDto(
            id: "movie-1", name: "Test", type: .movie,
            seriesName: nil, seriesId: nil, seasonId: nil, parentId: nil,
            indexNumber: nil, parentIndexNumber: nil, overview: nil,
            runTimeTicks: nil, userData: nil, imageTags: nil,
            backdropImageTags: nil, parentBackdropImageTags: nil,
            primaryImageAspectRatio: nil, mediaType: nil, libraryName: nil, productionYear: nil,
            communityRating: nil, officialRating: nil, genres: nil,
            taglines: nil, people: nil, criticRating: nil,
            premiereDate: nil, chapters: nil, path: nil, remoteTrailers: nil, localTrailerCount: nil, mediaStreams: nil
        )
        let viewModel = PlayerViewModel(client: JellyfinClient(), recoverySetup: { _, _, _, _ in })
        viewModel.currentItem = item
        viewModel.spatialAudio = stream
        await viewModel.attemptPlaybackRecovery(reason: "item-failed", itemID: item.id, attempt: viewModel.playbackAttempt)
        return viewModel
    }

    func testAStreamThatEndedItselfKeepsTheServersAudio() async {
        let stream = FakeStream(failed: true)
        let viewModel = await recover(from: stream)
        XCTAssertEqual(viewModel.refusedSpatialAudio, [stream.trackKey])
        XCTAssertTrue(stream.stopped)
    }

    func testAnotherFailureTriesSpatialAudioAgain() async {
        let stream = FakeStream(failed: false)
        let viewModel = await recover(from: stream)
        XCTAssertTrue(viewModel.refusedSpatialAudio.isEmpty, "the video, not the audio, failed")
        XCTAssertTrue(stream.stopped)
    }
}
