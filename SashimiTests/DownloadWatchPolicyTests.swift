import XCTest
@testable import Sashimi

/// Watch marks, "Remove watched" targeting and the delete-after-watching
/// decision behind the mobile Downloads screen.
final class DownloadWatchPolicyTests: XCTestCase {
    private let hour: Int64 = 36_000_000_000

    // MARK: - resolve

    func testServerPlayedWinsWhenNothingPendingLocally() {
        let state = DownloadWatchPolicy.resolve(
            server: ServerWatchState(played: true, positionTicks: 0),
            runTimeTicks: hour,
            localPositionTicks: hour / 4,
            localNeedsSync: false
        )
        XCTAssertEqual(state, DownloadWatchState(isPlayed: true, progress: 0))
    }

    func testServerPartialPositionShowsBar() {
        let state = DownloadWatchPolicy.resolve(
            server: ServerWatchState(played: false, positionTicks: hour / 2),
            runTimeTicks: hour,
            localPositionTicks: 0,
            localNeedsSync: false
        )
        XCTAssertFalse(state.isPlayed)
        XCTAssertEqual(state.progress, 0.5, accuracy: 0.0001)
    }

    func testUnsyncedLocalPositionOverridesServer() {
        // Watched offline to the end; the server still says a quarter in.
        let state = DownloadWatchPolicy.resolve(
            server: ServerWatchState(played: false, positionTicks: hour / 4),
            runTimeTicks: hour,
            localPositionTicks: hour - 1_000,
            localNeedsSync: true
        )
        XCTAssertEqual(state, DownloadWatchState(isPlayed: true, progress: 0))
    }

    func testUnsyncedPartialRewatchKeepsServerPlayed() {
        let state = DownloadWatchPolicy.resolve(
            server: ServerWatchState(played: true, positionTicks: 0),
            runTimeTicks: hour,
            localPositionTicks: hour / 5,
            localNeedsSync: true
        )
        XCTAssertTrue(state.isPlayed)
        XCTAssertEqual(state.progress, 0.2, accuracy: 0.0001)
    }

    func testOfflineFallbackUsesLocalPosition() {
        let partial = DownloadWatchPolicy.resolve(
            server: nil, runTimeTicks: hour, localPositionTicks: hour / 2, localNeedsSync: false
        )
        XCTAssertFalse(partial.isPlayed)
        XCTAssertEqual(partial.progress, 0.5, accuracy: 0.0001)

        let finished = DownloadWatchPolicy.resolve(
            server: nil, runTimeTicks: hour, localPositionTicks: hour * 95 / 100, localNeedsSync: false
        )
        XCTAssertEqual(finished, DownloadWatchState(isPlayed: true, progress: 0))
    }

    func testUnknownRuntimeOrUnstartedShowsNothing() {
        XCTAssertEqual(
            DownloadWatchPolicy.resolve(server: nil, runTimeTicks: nil, localPositionTicks: hour, localNeedsSync: true),
            .unwatched
        )
        XCTAssertEqual(
            DownloadWatchPolicy.resolve(server: nil, runTimeTicks: hour, localPositionTicks: 0, localNeedsSync: false),
            .unwatched
        )
    }

    func testServerStateDecodesFromUserData() throws {
        let json = Data(#"{"PlaybackPositionTicks": 42, "Played": true}"#.utf8)
        let userData = try JSONDecoder().decode(UserItemDataDto.self, from: json)
        XCTAssertEqual(ServerWatchState(userData: userData), ServerWatchState(played: true, positionTicks: 42))
        XCTAssertEqual(ServerWatchState(userData: nil), ServerWatchState(played: false, positionTicks: 0))
    }

    // MARK: - Remove watched

    func testWatchedTargetsAreOnlyCompletedPlayedItems() {
        let items = [
            DownloadWatchCandidate(recordID: "a", sizeBytes: 1_000, isComplete: true),
            DownloadWatchCandidate(recordID: "b", sizeBytes: 2_000, isComplete: true),
            DownloadWatchCandidate(recordID: "c", sizeBytes: 4_000, isComplete: false),
            DownloadWatchCandidate(recordID: "d", sizeBytes: 8_000, isComplete: true)
        ]
        let states: [String: DownloadWatchState] = [
            "a": DownloadWatchState(isPlayed: true, progress: 0),
            "b": DownloadWatchState(isPlayed: false, progress: 0.5),
            "c": DownloadWatchState(isPlayed: true, progress: 0)
            // "d" has no known state
        ]
        let targets = DownloadWatchPolicy.watchedTargets(items, states: states)
        XCTAssertEqual(targets.map(\.recordID), ["a"])
        XCTAssertEqual(DownloadWatchPolicy.totalBytes(targets), 1_000)
    }

    func testTotalBytesSumsAndIgnoresNegativeSizes() {
        let items = [
            DownloadWatchCandidate(recordID: "a", sizeBytes: 1_500_000_000, isComplete: true),
            DownloadWatchCandidate(recordID: "b", sizeBytes: 500_000_000, isComplete: true),
            DownloadWatchCandidate(recordID: "c", sizeBytes: -1, isComplete: true)
        ]
        XCTAssertEqual(DownloadWatchPolicy.totalBytes(items), 2_000_000_000)
        XCTAssertEqual(DownloadWatchPolicy.totalBytes([]), 0)
    }

    // MARK: - Delete after watching

    private func autoDeletes(
        enabled: Bool = true, complete: Bool = true, position: Int64, runTime: Int64?, reachedEnd: Bool = false
    ) -> Bool {
        DownloadWatchPolicy.shouldAutoDelete(
            settingEnabled: enabled,
            isCompletedDownload: complete,
            positionTicks: position,
            runTimeTicks: runTime,
            reachedEnd: reachedEnd
        )
    }

    func testAutoDeleteRequiresTheSettingAndACompletedDownload() {
        XCTAssertTrue(autoDeletes(position: hour, runTime: hour, reachedEnd: true))
        XCTAssertFalse(autoDeletes(enabled: false, position: hour, runTime: hour, reachedEnd: true))
        XCTAssertFalse(autoDeletes(complete: false, position: hour, runTime: hour, reachedEnd: true))
    }

    /// Stopped in the credits: the server marks it watched, so it goes.
    func testStoppingPastTheWatchedLineDeletes() {
        XCTAssertTrue(autoDeletes(position: hour * 92 / 100, runTime: hour))
        XCTAssertTrue(autoDeletes(position: hour * 90 / 100, runTime: hour))
    }

    func testStoppingBeforeTheWatchedLineKeepsIt() {
        XCTAssertFalse(autoDeletes(position: hour * 89 / 100, runTime: hour))
        XCTAssertFalse(autoDeletes(position: 0, runTime: hour))
    }

    /// No runtime to measure against: only playing to the end counts.
    func testUnknownRuntimeNeedsTheEnd() {
        XCTAssertFalse(autoDeletes(position: hour, runTime: nil))
        XCTAssertTrue(autoDeletes(position: hour, runTime: nil, reachedEnd: true))
    }
}
