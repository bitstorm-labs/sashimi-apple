import XCTest
import AVFoundation
@testable import Sashimi

/// Behaviour tests for the 2026-10-02 streaming audit fixes (#591, #592, #593,
/// #595), driven through the production view model.
///
/// Everything here is written against API that already existed before the
/// fixes, so the file compiles against the old code and each test fails there
/// on its assertion rather than on a missing symbol.
@MainActor
final class PlayerAuditBehaviourTests: XCTestCase {
    private let fortyMinutes: Int64 = 24_000_000_000

    // MARK: - #591 leaving the player

    func testLeavingReleasesThePlayerBeforeTheStoppedReportIsDelivered() async {
        let reporter = SuspendingStopReporter()
        let viewModel = makeViewModel(reporter: reporter)
        viewModel.player = AVPlayer(playerItem: idleItem())
        viewModel.playbackStartDate = Date().addingTimeInterval(-120)

        let stop = viewModel.beginStop(reason: .userStop)

        // Nothing has been awaited: this is the state the view dismisses on.
        XCTAssertNil(viewModel.player, "the player must be released before any network work")
        XCTAssertNil(viewModel.currentItem)

        // The report is still in flight behind the dismissal...
        await fulfillment(of: [reporter.stopStarted], timeout: 2)
        XCTAssertNil(viewModel.player)
        // ...and still completes.
        reporter.release()
        await stop.value
        XCTAssertEqual(reporter.stoppedItemIDs, ["episode-1"])
    }

    // MARK: - #592 a pause is not a stall

    func testStallWatchdogLeavesAPausedPlayerAlone() async {
        let recoveries = Counter()
        let viewModel = PlayerViewModel(
            client: JellyfinClient(),
            reporter: RecordingPositionReporter(),
            recoverySetup: { _, _, _, _ in recoveries.value += 1 }
        )
        let item = makeItem()
        viewModel.currentItem = item
        // Never told to play: timeControlStatus is .paused, position unmoved.
        // Exactly what the watchdog sees after the viewer presses pause.
        let player = AVPlayer(playerItem: idleItem())
        viewModel.player = player

        viewModel.armStallWatchdog(
            for: PlayerViewModel.PlaybackGeneration(itemID: item.id, attempt: viewModel.playbackAttempt),
            grace: 0.05
        )
        try? await Task.sleep(for: .milliseconds(700))

        XCTAssertEqual(recoveries.value, 0, "a paused player must not be rebuilt")
        XCTAssertEqual(viewModel.recoveryAttempts, 0, "and must not spend the recovery budget")
        XCTAssertTrue(viewModel.player === player, "the paused player must be left in place")
    }

    // MARK: - #593 position while a rebuilt stream loads

    func testExitWhileRebuiltStreamLoadsReportsThePendingPosition() async {
        let reporter = RecordingPositionReporter()
        let viewModel = makeViewModel(reporter: reporter)
        // A rebuilt item that is not ready yet: its clock reads zero and the
        // real position is waiting in pendingResumeTicks.
        viewModel.player = AVPlayer(playerItem: idleItem())
        viewModel.pendingResumeTicks = fortyMinutes
        viewModel.playbackStartDate = Date().addingTimeInterval(-120)

        await viewModel.stop(reason: .userStop)

        XCTAssertEqual(reporter.preparedTicks, [fortyMinutes])
        XCTAssertEqual(reporter.stoppedTicks, [fortyMinutes])
    }

    func testExitBeforeTheRebuiltPlayerExistsStillReportsThePendingPosition() async {
        let reporter = RecordingPositionReporter()
        let viewModel = makeViewModel(reporter: reporter)
        // Mid-rebuild: the old player is gone and the new one is not built.
        viewModel.player = nil
        viewModel.pendingResumeTicks = fortyMinutes
        viewModel.playbackStartDate = Date().addingTimeInterval(-120)

        await viewModel.stop(reason: .userStop)

        XCTAssertEqual(reporter.stoppedTicks, [fortyMinutes])
    }

    func testProgressReportWhileRebuiltStreamLoadsCarriesThePendingPosition() async {
        let reporter = RecordingPositionReporter()
        let viewModel = makeViewModel(reporter: reporter)
        viewModel.player = AVPlayer(playerItem: idleItem())
        viewModel.pendingResumeTicks = fortyMinutes

        await viewModel.reportProgress()

        XCTAssertEqual(reporter.progressTicks, [fortyMinutes])
    }

    func testManualSkipWhileRebuiltStreamLoadsReportsThePendingPosition() async {
        let reporter = RecordingPositionReporter()
        let viewModel = makeViewModel(reporter: reporter)
        viewModel.player = AVPlayer(playerItem: idleItem())
        viewModel.pendingResumeTicks = fortyMinutes
        viewModel.playbackStartDate = Date().addingTimeInterval(-120)

        await viewModel.reportCurrentPlaybackStoppedForTransition()

        XCTAssertEqual(reporter.stoppedTicks, [fortyMinutes])
    }

    // MARK: - #595 image subtitles are never auto-selected

    func testSettingsPreferenceSkipsImageSubtitlesForATextTrack() {
        let streams = [
            subtitle(codec: "PGSSUB", language: "eng", index: 2, isDefault: true),
            subtitle(codec: "subrip", language: "eng", index: 3)
        ]
        let picked = PlaybackSelection.preferredSubtitleStream(
            from: streams, preferredLanguage: "en", subtitlesEnabled: true
        )
        XCTAssertEqual(picked?.index, 3)
    }

    func testSettingsPreferenceSelectsNothingWhenOnlyImageSubtitlesExist() {
        let streams = [
            subtitle(codec: "PGSSUB", language: "eng", index: 2, isDefault: true),
            subtitle(codec: "dvdsub", language: "eng", index: 3)
        ]
        XCTAssertNil(PlaybackSelection.preferredSubtitleStream(
            from: streams, preferredLanguage: "en", subtitlesEnabled: true
        ))
    }

    // MARK: - Helpers

    private func makeViewModel(reporter: any PlayerPlaybackReporting) -> PlayerViewModel {
        let viewModel = PlayerViewModel(client: JellyfinClient(), reporter: reporter)
        viewModel.currentItem = makeItem()
        return viewModel
    }

    /// An item that never becomes ready: its clock stays at zero, like a
    /// rebuilt HLS item that is still loading.
    private func idleItem() -> AVPlayerItem {
        AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent/sashimi-test.mp4"))
    }

    private func subtitle(codec: String, language: String, index: Int, isDefault: Bool? = nil) -> MediaStream {
        MediaStream(
            type: "Subtitle", codec: codec, language: language, displayTitle: "\(language) \(codec)",
            title: nil, height: nil, width: nil, channels: nil, index: index, isDefault: isDefault,
            isExternal: false, isForced: nil, videoRangeType: nil, bitRate: nil,
            deliveryUrl: nil, deliveryMethod: nil
        )
    }

    private func makeItem() -> BaseItemDto {
        BaseItemDto(
            id: "episode-1", name: "Episode", type: .episode, seriesName: "Series", seriesId: "series",
            seasonId: "season", parentId: "season", indexNumber: 1, parentIndexNumber: 1, overview: nil,
            runTimeTicks: nil, userData: nil, imageTags: nil, backdropImageTags: nil,
            parentBackdropImageTags: nil, primaryImageAspectRatio: nil, mediaType: nil,
            libraryName: "Shows", productionYear: 2026, communityRating: nil, officialRating: nil,
            genres: nil, taglines: nil, people: nil, criticRating: nil, premiereDate: nil, chapters: nil,
            path: nil, remoteTrailers: nil, localTrailerCount: nil, mediaStreams: nil
        )
    }
}

@MainActor
private final class Counter {
    var value = 0
}

/// Records the position each report carried.
@MainActor
private final class RecordingPositionReporter: PlayerPlaybackReporting {
    private(set) var preparedTicks: [Int64] = []
    private(set) var stoppedTicks: [Int64] = []
    private(set) var progressTicks: [Int64] = []

    func reset() {}
    func prepareStopped(itemID: String, positionTicks: Int64, playSessionID: String?) {
        preparedTicks.append(positionTicks)
    }
    func start(itemID: String, positionTicks: Int64, playSessionID: String?, playMethod: String) async {}
    func progress(itemID: String, positionTicks: Int64, isPaused: Bool, playSessionID: String?) async {
        progressTicks.append(positionTicks)
    }
    func stopped(itemID: String, positionTicks: Int64, playSessionID: String?) async {
        stoppedTicks.append(positionTicks)
    }
    func completed(itemID: String, positionTicks: Int64, playSessionID: String?) async {}
}

/// A stopped report that does not come back until released: a slow server.
@MainActor
private final class SuspendingStopReporter: PlayerPlaybackReporting {
    let stopStarted = XCTestExpectation(description: "Stopped report started")
    private(set) var stoppedItemIDs: [String] = []
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func reset() {}
    func prepareStopped(itemID: String, positionTicks: Int64, playSessionID: String?) {}
    func start(itemID: String, positionTicks: Int64, playSessionID: String?, playMethod: String) async {}
    func progress(itemID: String, positionTicks: Int64, isPaused: Bool, playSessionID: String?) async {}
    func completed(itemID: String, positionTicks: Int64, playSessionID: String?) async {}

    func stopped(itemID: String, positionTicks: Int64, playSessionID: String?) async {
        stopStarted.fulfill()
        if !released {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        stoppedItemIDs.append(itemID)
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
