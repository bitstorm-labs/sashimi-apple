import AVFoundation
import XCTest
@testable import SashimiMobile

/// #799 follow-up: the Mac player hides the pointer only while it plays, and
/// learns that from `timeControlStatusUpdates()`. The stream must carry every
/// change, not just the status at the moment iteration began; the Combine
/// KVO publisher's `.values` delivered the initial `.paused` and nothing
/// after, so the pointer never hid on a real Mac.
@MainActor
final class PlayerTimeControlStatusUpdatesTests: XCTestCase {
    func testDeliversChangesAfterTheInitialStatus() async throws {
        let player = AVPlayer()
        let sawPaused = expectation(description: "initial .paused")
        let sawNotPaused = expectation(description: "a change away from .paused")

        let watcher = Task { @MainActor in
            var sawInitial = false
            for await status in player.timeControlStatusUpdates() {
                if !sawInitial {
                    sawInitial = true
                    if status == .paused { sawPaused.fulfill() }
                } else if status != .paused {
                    sawNotPaused.fulfill()
                    return
                }
            }
        }
        defer { watcher.cancel() }

        await fulfillment(of: [sawPaused], timeout: 2)
        player.play()
        await fulfillment(of: [sawNotPaused], timeout: 2)
    }
}
