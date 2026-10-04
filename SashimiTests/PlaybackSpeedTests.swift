import AVFoundation
import XCTest
@testable import Sashimi

/// The speed menu's choice must survive pause/resume (#607).
@MainActor
final class PlaybackSpeedTests: XCTestCase {
    func testSpeedChosenWhilePlayingSurvivesPauseAndResume() {
        let player = AVPlayer()
        player.play()
        PlaybackSpeed.apply(1.5, to: player)
        XCTAssertEqual(player.rate, 1.5)

        player.pause()
        player.play()

        XCTAssertEqual(player.rate, 1.5, "play() resumes at defaultRate; the old menu set only rate, so this was 1.0")
    }

    func testSpeedChosenWhilePausedAppliesOnResumeWithoutUnpausing() {
        let player = AVPlayer()
        PlaybackSpeed.apply(2.0, to: player)
        XCTAssertEqual(player.rate, 0, "picking a speed must not start playback")

        player.play()

        XCTAssertEqual(player.rate, 2.0)
    }

    func testMenuReportsTheChosenSpeedWhilePaused() {
        let player = AVPlayer()
        player.play()
        PlaybackSpeed.apply(1.25, to: player)
        player.pause()

        XCTAssertEqual(PlaybackSpeed.current(of: player), 1.25)
    }

    func testDefaultSpeedIsNormal() {
        XCTAssertEqual(PlaybackSpeed.current(of: AVPlayer()), 1.0)
    }
}
