import XCTest
@testable import Sashimi

/// Pure-logic tests for the 2026-10-02 streaming audit fixes: what the
/// PlaybackInfo request says about tracks (#590), the pause-vs-stall verdict
/// (#592), the reported position (#593), the load deadline (#594) and
/// subtitle response handling (#595).
@MainActor
final class PlayerAuditLogicTests: XCTestCase {
    // MARK: - #590 PlaybackInfo body

    private func body(_ tracks: StreamTrackRequest) -> [String: Any] {
        JellyfinClient.playbackInfoBody(
            userId: "user",
            streamingBitrate: 20_000_000,
            deviceProfile: [:],
            tracks: tracks
        )
    }

    func testBodyNamesTheMediaSourceAndAsksForNoSubtitleByDefault() {
        let body = body(StreamTrackRequest(mediaSourceId: "item-1"))

        // Without MediaSourceId the server ignores both indexes.
        XCTAssertEqual(body["MediaSourceId"] as? String, "item-1")
        // -1, not absent: absent means "the Jellyfin user's default subtitle",
        // which the server burns in when it is an image format.
        XCTAssertEqual(body["SubtitleStreamIndex"] as? Int, -1)
        XCTAssertNil(body["AudioStreamIndex"], "no pick leaves the audio default to the server")
    }

    func testBodyCarriesTheChosenAudioStream() {
        let body = body(StreamTrackRequest(mediaSourceId: "item-1", audioStreamIndex: 2))
        XCTAssertEqual(body["AudioStreamIndex"] as? Int, 2)
        XCTAssertEqual(body["SubtitleStreamIndex"] as? Int, -1)
    }

    func testBodyCarriesARequestedBurnInSubtitle() {
        let request = StreamTrackRequest(mediaSourceId: "item-1", audioStreamIndex: 1, subtitleStreamIndex: 4)
        XCTAssertTrue(request.burnsInSubtitle)
        XCTAssertEqual(body(request)["SubtitleStreamIndex"] as? Int, 4)
        XCTAssertFalse(StreamTrackRequest(mediaSourceId: "item-1").burnsInSubtitle)
    }

    // MARK: - #590 which audio stream

    private let japaneseDefault = [
        PlayerAuditLogicTests.stream("Video", codec: "hevc", language: nil, index: 0),
        PlayerAuditLogicTests.stream("Audio", codec: "eac3", language: "jpn", index: 1, isDefault: true, title: "Japanese 5.1"),
        PlayerAuditLogicTests.stream("Audio", codec: "eac3", language: "eng", index: 2, title: "English 5.1"),
        PlayerAuditLogicTests.stream("Audio", codec: "ac3", language: "eng", index: 3, title: "English Commentary")
    ]

    func testPreferredAudioLanguageResolvesToAStreamIndex() {
        XCTAssertEqual(
            PlaybackSelection.audioStreamIndex(in: japaneseDefault, session: nil, preferredLanguage: "en"),
            2
        )
    }

    func testNoPreferenceAndNoMatchLeaveTheServerDefault() {
        XCTAssertNil(PlaybackSelection.audioStreamIndex(in: japaneseDefault, session: nil, preferredLanguage: ""))
        XCTAssertNil(PlaybackSelection.audioStreamIndex(in: japaneseDefault, session: nil, preferredLanguage: "fr"))
    }

    func testSessionPickBeatsTheSettingsLanguage() {
        let pick = PlaybackSelection.AudioIntent(language: "eng", displayName: "English Commentary")
        XCTAssertEqual(
            PlaybackSelection.audioStreamIndex(in: japaneseDefault, session: pick, preferredLanguage: "ja"),
            3
        )
    }

    func testSessionPickFallsBackToItsLanguageOnAnotherSource() {
        // The next episode names its tracks differently; the language holds.
        let pick = PlaybackSelection.AudioIntent(language: "eng", displayName: "English Stereo")
        XCTAssertEqual(
            PlaybackSelection.audioStreamIndex(in: japaneseDefault, session: pick, preferredLanguage: ""),
            2
        )
    }

    func testDefaultFlaggedStreamWinsAmongSeveralInTheLanguage() {
        let streams = [
            Self.stream("Audio", codec: "ac3", language: "eng", index: 1, title: "Commentary"),
            Self.stream("Audio", codec: "eac3", language: "eng", index: 2, isDefault: true, title: "Main")
        ]
        XCTAssertEqual(PlaybackSelection.audioStreamIndex(in: streams, session: nil, preferredLanguage: "en"), 2)
    }

    func testTrackRequestCombinesAudioAndSubtitleIntent() {
        let request = PlaybackSelection.streamTrackRequest(
            mediaSourceId: "source",
            streams: japaneseDefault,
            audio: nil,
            preferredAudioLanguage: "en",
            subtitle: nil
        )
        XCTAssertEqual(request, StreamTrackRequest(mediaSourceId: "source", audioStreamIndex: 2, subtitleStreamIndex: -1))
    }

    // MARK: - #590 second pass

    func testNoRetryWhenTheServerAlreadyPlaysTheWantedAudio() {
        let sent = StreamTrackRequest(mediaSourceId: "a")
        let resolved = StreamTrackRequest(mediaSourceId: "a", audioStreamIndex: 1)
        XCTAssertFalse(PlaybackSelection.needsTrackRetry(sent: sent, resolved: resolved, serverAudioStreamIndex: 1))
    }

    func testRetryWhenTheResponseRevealsADifferentWantedAudio() {
        // The item arrived without streams, so nothing could be asked for.
        let sent = StreamTrackRequest(mediaSourceId: "a")
        let resolved = StreamTrackRequest(mediaSourceId: "a", audioStreamIndex: 2)
        XCTAssertTrue(PlaybackSelection.needsTrackRetry(sent: sent, resolved: resolved, serverAudioStreamIndex: 1))
    }

    func testRetryWhenTheServerPlaysADifferentSource() {
        // The indexes were ignored: they were sent against the wrong source.
        let sent = StreamTrackRequest(mediaSourceId: "item", audioStreamIndex: 2)
        let resolved = StreamTrackRequest(mediaSourceId: "version-b", audioStreamIndex: 2)
        XCTAssertTrue(PlaybackSelection.needsTrackRetry(sent: sent, resolved: resolved, serverAudioStreamIndex: 2))
    }

    func testRetryWhenTheBurnInOnlyResolvesAgainstTheResponse() {
        let sent = StreamTrackRequest(mediaSourceId: "a")
        let resolved = StreamTrackRequest(mediaSourceId: "a", subtitleStreamIndex: 4)
        XCTAssertTrue(PlaybackSelection.needsTrackRetry(sent: sent, resolved: resolved, serverAudioStreamIndex: nil))
    }

    func testNoRetryWhenNothingChanged() {
        let sent = StreamTrackRequest(mediaSourceId: "a", audioStreamIndex: 2)
        XCTAssertFalse(PlaybackSelection.needsTrackRetry(sent: sent, resolved: sent, serverAudioStreamIndex: 2))
    }

    // MARK: - #595 image subtitles

    func testImageSubtitleCodecsAreRecognisedInEitherCase() {
        for codec in ["PGSSUB", "pgssub", "dvdsub", "DVDSUB", "dvbsub", "hdmv_pgs_subtitle", "dvd_subtitle", "sub", "sup"] {
            XCTAssertTrue(PlaybackSelection.isImageSubtitle(codec: codec), codec)
        }
        for codec in ["subrip", "srt", "ass", "ssa", "webvtt", "vtt", "mov_text", "microdvd", nil] {
            XCTAssertFalse(PlaybackSelection.isImageSubtitle(codec: codec), codec ?? "nil")
        }
    }

    private let mixedSubtitles = [
        PlayerAuditLogicTests.stream("Subtitle", codec: "PGSSUB", language: "eng", index: 2, isDefault: true, title: "English (PGS)"),
        PlayerAuditLogicTests.stream("Subtitle", codec: "subrip", language: "eng", index: 3, title: "English (SRT)")
    ]

    func testPickingAnImageSubtitleAsksTheServerToBurnItIn() {
        let pick = PlaybackSelection.SubtitleIntent(language: "eng", displayTitle: "English (PGS)", isExternal: false)
        XCTAssertEqual(PlaybackSelection.burnInSubtitleIndex(in: mixedSubtitles, session: pick), 2)
    }

    func testPickingATextSubtitleNeverBurnsIn() {
        let pick = PlaybackSelection.SubtitleIntent(language: "eng", displayTitle: "English (SRT)", isExternal: false)
        XCTAssertEqual(PlaybackSelection.burnInSubtitleIndex(in: mixedSubtitles, session: pick), -1)
    }

    func testNoPickNeverBurnsInEvenWhenTheDefaultIsAnImageSubtitle() {
        XCTAssertEqual(PlaybackSelection.burnInSubtitleIndex(in: mixedSubtitles, session: nil), -1)
    }

    // MARK: - #595 subtitle response

    func testServerErrorBodyIsNotTreatedAsSubtitles() throws {
        let body = Data("Error processing request.".utf8)
        XCTAssertNil(SubtitleManager.vttText(from: body, response: try response(status: 500)))
        XCTAssertNil(SubtitleManager.vttText(from: body, response: try response(status: 404)))
    }

    func testSuccessfulResponseYieldsItsText() throws {
        let vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHello"
        XCTAssertEqual(SubtitleManager.vttText(from: Data(vtt.utf8), response: try response(status: 200)), vtt)
    }

    private func response(status: Int) throws -> URLResponse {
        try XCTUnwrap(HTTPURLResponse(
            url: try XCTUnwrap(URL(string: "http://server.test/Videos/a/a/Subtitles/2/Stream.vtt")),
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        ))
    }

    // MARK: - #592 pause vs stall

    func testAPausedPlayerIsNeverAStall() {
        XCTAssertEqual(PlaybackRecoveryPlan.stallVerdict(timeControl: .paused, positionDelta: 0), .waitForResume)
        XCTAssertEqual(PlaybackRecoveryPlan.stallVerdict(timeControl: .paused, positionDelta: 30), .waitForResume)
    }

    func testAPlayerThatWantsToPlayAndHasNotMovedIsAStall() {
        XCTAssertEqual(PlaybackRecoveryPlan.stallVerdict(timeControl: .waiting, positionDelta: 0), .recover)
        XCTAssertEqual(PlaybackRecoveryPlan.stallVerdict(timeControl: .waiting, positionDelta: 0.3), .recover)
    }

    func testBufferingThatMovedOnAndRunningPlaybackStandDown() {
        XCTAssertEqual(PlaybackRecoveryPlan.stallVerdict(timeControl: .waiting, positionDelta: 4), .standDown)
        XCTAssertEqual(PlaybackRecoveryPlan.stallVerdict(timeControl: .playing, positionDelta: 0), .standDown)
        // A clock that cannot be read is not evidence of a stall.
        XCTAssertEqual(PlaybackRecoveryPlan.stallVerdict(timeControl: .waiting, positionDelta: .nan), .standDown)
    }

    // MARK: - #593 reported position

    func testPendingResumeOutranksTheItemClock() {
        XCTAssertEqual(
            PlaybackPosition.ticks(currentSeconds: 0, pendingResumeTicks: 24_000_000_000, secondsSinceStart: 300),
            24_000_000_000
        )
        // Even with no player at all (mid-rebuild).
        XCTAssertEqual(PlaybackPosition.ticks(currentSeconds: nil, pendingResumeTicks: 24_000_000_000), 24_000_000_000)
    }

    func testQuickExitKeepsTheOriginalResumePoint() {
        XCTAssertEqual(
            PlaybackPosition.ticks(currentSeconds: 2, pendingResumeTicks: 0, resumePositionTicks: 9_000, secondsSinceStart: 4),
            9_000
        )
    }

    func testOtherwiseTheItemClockIsThePosition() {
        XCTAssertEqual(
            PlaybackPosition.ticks(currentSeconds: 90, pendingResumeTicks: 0, resumePositionTicks: 9_000, secondsSinceStart: 60),
            900_000_000
        )
    }

    func testAnUnreadableClockReportsNothingRatherThanZero() {
        XCTAssertNil(PlaybackPosition.ticks(currentSeconds: .nan, pendingResumeTicks: 0))
        XCTAssertNil(PlaybackPosition.ticks(currentSeconds: nil, pendingResumeTicks: 0))
    }

    // MARK: - #594 load deadline

    func testVerdictIsAboutSilenceNotElapsedTime() {
        XCTAssertEqual(PlaybackLoadPolicy.verdict(secondsSinceProgress: 5.1), .keepWaiting)
        XCTAssertEqual(PlaybackLoadPolicy.verdict(secondsSinceProgress: 19.9), .keepWaiting)
        XCTAssertEqual(PlaybackLoadPolicy.verdict(secondsSinceProgress: 20), .giveUp)
    }

    func testALoadThatGoesQuietIsCancelledWithATimeoutError() async {
        let viewModel = PlayerViewModel(client: JellyfinClient())
        viewModel.loadStallBudget = 0.3
        let started = Date()
        do {
            try await viewModel.withLoadDeadline {
                try await Task.sleep(for: .seconds(30))
            }
            XCTFail("a silent load must not complete")
        } catch PlayerError.loadTimedOut {
            XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the hung work must be cancelled, not awaited")
        } catch {
            XCTFail("expected loadTimedOut, got \(error)")
        }
    }

    func testASlowLoadThatKeepsAnsweringIsNotInterrupted() async throws {
        let viewModel = PlayerViewModel(client: JellyfinClient())
        viewModel.loadStallBudget = 0.5
        // 1.2 s in total, well past the budget, but never silent for 0.5 s.
        try await viewModel.withLoadDeadline {
            for _ in 0..<6 {
                try await Task.sleep(for: .milliseconds(200))
                viewModel.noteLoadProgress()
            }
        }
    }

    func testTimeoutMessagesSayWhatHappened() {
        XCTAssertEqual(
            PlayerError.loadTimedOut(serverReachable: false).errorDescription,
            "Can't reach the server. Check your connection and try again."
        )
        XCTAssertEqual(
            PlayerError.loadTimedOut(serverReachable: true).errorDescription,
            "The server is taking too long to respond. Try again in a moment."
        )
    }

    // MARK: - Helpers

    nonisolated private static func stream(
        _ type: String,
        codec: String,
        language: String?,
        index: Int,
        isDefault: Bool? = nil,
        title: String? = nil
    ) -> MediaStream {
        MediaStream(
            type: type, codec: codec, language: language, displayTitle: title, title: nil,
            height: nil, width: nil, channels: nil, index: index, isDefault: isDefault,
            isExternal: false, isForced: nil, videoRangeType: nil, bitRate: nil,
            deliveryUrl: nil, deliveryMethod: nil
        )
    }
}
