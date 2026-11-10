import XCTest
import AVFoundation
import AVKit
import SwiftUI
@testable import Sashimi

/// "When she rewound, the audio kept playing — and when she exited and came
/// back it did the same thing" (Apple TV, 1.6.92).
///
/// The server log for that session shows segment requests arriving for play
/// sessions the app had already stopped: one eight seconds after its stopped
/// report, another seven minutes after. A stopped player was still running.
///
/// Two faults let that happen, and each is tested here against API that
/// existed before the fix, so the file compiles on the old code and fails
/// there on its assertions:
///
/// 1. Every place that dropped a player only PAUSED it. A paused AVPlayer
///    still holds its stream: anything that later calls `play()` on it (AVKit
///    finishing a scrub restores the rate it had before, the system's
///    play/pause routing) brings its audio back, under the replacement
///    player or after the screen has gone.
/// 2. The tvOS player screen never let go of that player: the skip button's
///    callback held the coordinator strongly while the coordinator held the
///    skip button and the AVPlayerViewController, so every screen leaked its
///    controller and, through it, its AVPlayer.
@MainActor
final class RetiredPlayerSilenceTests: XCTestCase {
    // MARK: - The view model empties every player it lets go of

    func testLeavingEmptiesTheOutgoingPlayer() async {
        let viewModel = PlayerViewModel(client: JellyfinClient(), reporter: SilentReporter())
        viewModel.currentItem = makeItem()
        let outgoing = AVPlayer(playerItem: idleItem())
        viewModel.player = outgoing
        viewModel.playbackStartDate = Date().addingTimeInterval(-120)

        await viewModel.stop(reason: .userStop)

        XCTAssertNil(outgoing.currentItem, "a stopped player must have nothing left to play")
        // What AVKit or the system's play/pause routing can still do to an
        // instance it holds: it must produce nothing.
        outgoing.play()
        XCTAssertNil(outgoing.currentItem)
    }

    func testStallRecoveryEmptiesThePlayerItReplaces() async {
        let rebuilt = AVPlayer(playerItem: idleItem())
        var viewModelRef: PlayerViewModel?
        let viewModel = PlayerViewModel(
            client: JellyfinClient(),
            reporter: SilentReporter(),
            recoverySetup: { _, _, _, _ in viewModelRef?.player = rebuilt }
        )
        viewModelRef = viewModel
        let item = makeItem()
        viewModel.currentItem = item
        let outgoing = AVPlayer(playerItem: idleItem())
        viewModel.player = outgoing

        // A backwards seek on a stream-copy remux: the server restarts ffmpeg
        // for every skip, the item stalls, the watchdog rebuilds the stream.
        await viewModel.attemptPlaybackRecovery(
            reason: PlayerViewModel.stallRecoveryReason,
            itemID: item.id,
            attempt: viewModel.playbackAttempt
        )

        XCTAssertTrue(viewModel.player === rebuilt, "recovery must have installed the rebuilt player")
        XCTAssertNil(outgoing.currentItem, "the stalled player must not be able to resume its audio")
        XCTAssertNotNil(rebuilt.currentItem)
    }

    // MARK: - The tvOS player screen lets go of its player

    func testClosingThePlayerScreenReleasesItsPlayer() async throws {
        let viewModel = PlayerViewModel(client: JellyfinClient(), reporter: SilentReporter())
        let item = makeItem()
        viewModel.currentItem = item

        weak var weakPlayer: AVPlayer?
        weak var weakController: AVPlayerViewController?
        var window: UIWindow? = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))

        do {
            let player = AVPlayer(playerItem: idleItem())
            weakPlayer = player
            viewModel.player = player
            let host = UIHostingController(rootView: TVPlayerView(
                player: player,
                viewModel: viewModel,
                item: item,
                onDismiss: {}
            ))
            window?.rootViewController = host
            window?.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            await settle()
            weakController = Self.findPlayerController(in: host)
            XCTAssertNotNil(weakController, "the screen must have built its AVPlayerViewController")
        }

        // The screen goes away and the view model lets go, as on Back.
        viewModel.player = nil
        window?.rootViewController = nil
        window?.isHidden = true
        window = nil
        await settle()

        // AVKit releases its controller a beat after the hierarchy goes, so
        // wait for the condition, bounded, rather than for a fixed time.
        await waitUntil { weakController == nil && weakPlayer == nil }

        XCTAssertNil(weakController, "the AVPlayerViewController must not outlive its screen")
        XCTAssertNil(weakPlayer, "nothing may keep the AVPlayer alive once the screen and view model let go")
    }

    // MARK: - Helpers

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            await settle()
        }
    }

    private func settle() async {
        for _ in 0..<5 {
            await Task.yield()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private static func findPlayerController(in controller: UIViewController) -> AVPlayerViewController? {
        if let player = controller as? AVPlayerViewController { return player }
        for child in controller.children {
            if let found = findPlayerController(in: child) { return found }
        }
        return nil
    }

    private func idleItem() -> AVPlayerItem {
        AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent/sashimi-test.mp4"))
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
private final class SilentReporter: PlayerPlaybackReporting {
    func reset() {}
    func prepareStopped(itemID: String, positionTicks: Int64, playSessionID: String?) {}
    func start(itemID: String, positionTicks: Int64, playSessionID: String?, playMethod: String) async {}
    func progress(itemID: String, positionTicks: Int64, isPaused: Bool, playSessionID: String?) async {}
    func stopped(itemID: String, positionTicks: Int64, playSessionID: String?) async {}
    func completed(itemID: String, positionTicks: Int64, playSessionID: String?) async {}
}
