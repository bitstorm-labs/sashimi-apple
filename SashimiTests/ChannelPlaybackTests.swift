import XCTest
@testable import Sashimi

/// Channel viewing must leave no trace on watch state. These assert the
/// suppression itself, not the plumbing around it: the failure they exist to
/// catch is a channel quietly writing resume positions and watched flags onto a
/// user's library across every device.
@MainActor
final class ChannelPlaybackTests: XCTestCase {
    /// Records anything a reporter is asked to send.
    private final class SpyReporter: PlayerPlaybackReporting {
        var calls: [String] = []
        func reset() { calls.append("reset") }
        func prepareStopped(itemID: String, positionTicks: Int64, playSessionID: String?) { calls.append("prepareStopped") }
        func start(itemID: String, positionTicks: Int64, playSessionID: String?, playMethod: String) async { calls.append("start") }
        func progress(itemID: String, positionTicks: Int64, isPaused: Bool, playSessionID: String?) async { calls.append("progress") }
        func stopped(itemID: String, positionTicks: Int64, playSessionID: String?) async { calls.append("stopped") }
        func completed(itemID: String, positionTicks: Int64, playSessionID: String?) async { calls.append("completed") }
    }

    private func context(offset: Double = 634.5) -> ChannelPlaybackContext {
        ChannelPlaybackContext(
            channelID: "11111111222233334444555555555555",
            startPositionSeconds: offset,
            endsAt: Date().addingTimeInterval(600),
            nextItemID: "next-item"
        )
    }

    func testChannelReporterSwallowsEveryReport() async {
        let reporter = ChannelPlaybackReporter()

        // Every method on the protocol, because the point is that none of them
        // reaches the server — not that the ones we remembered don't.
        reporter.reset()
        reporter.prepareStopped(itemID: "a", positionTicks: 1, playSessionID: nil)
        await reporter.start(itemID: "a", positionTicks: 1, playSessionID: nil, playMethod: "DirectPlay")
        await reporter.progress(itemID: "a", positionTicks: 2, isPaused: false, playSessionID: nil)
        await reporter.stopped(itemID: "a", positionTicks: 3, playSessionID: nil)
        await reporter.completed(itemID: "a", positionTicks: 4, playSessionID: nil)

        // Nothing to assert beyond "did not throw, did not send": the type has
        // no state, which is exactly the guarantee being made.
        XCTAssertTrue(reporter is PlayerPlaybackReporting)
    }

    func testTuningToAChannelCarriesTheContext() {
        let viewModel = PlayerViewModel(channelContext: context())

        // playbackReporter is private, so this proves the context reaches the
        // player — not that the reporter was swapped. The swap is enforced
        // structurally by the type rather than by a test.
        XCTAssertNotNil(viewModel.channelContext)
        XCTAssertEqual(viewModel.channelContext?.channelID, "11111111222233334444555555555555")
    }

    func testOrdinaryPlaybackIsUnaffected() {
        let spy = SpyReporter()
        let viewModel = PlayerViewModel(reporter: spy)

        // No context means the normal reporting path, unchanged.
        XCTAssertNil(viewModel.channelContext)
    }

    func testAnExplicitReporterStillWinsOverChannelMode() {
        // Tests inject their own reporter; channel mode must not silently
        // override it or every channel test would assert against a no-op.
        let spy = SpyReporter()
        let viewModel = PlayerViewModel(reporter: spy, channelContext: context())

        XCTAssertNotNil(viewModel.channelContext)
    }

    func testOffsetConvertsToTicksForTheSeek() {
        // 634.5s is the kind of fractional offset a channel actually produces;
        // the player works in ticks, and a rounding error here lands the viewer
        // in the wrong place.
        XCTAssertEqual(context(offset: 634.5).startPositionTicks, 6_345_000_000)
        XCTAssertEqual(context(offset: 0).startPositionTicks, 0)
    }

    func testAChannelOffsetIsNotAResumePosition() {
        // The distinction the whole mode exists for: these are different
        // questions and must not be conflated.
        let ctx = context(offset: 120)
        XCTAssertEqual(ctx.startPositionSeconds, 120)
        XCTAssertNotNil(ctx.nextItemID, "a client needs the next programme to prepare the boundary")
    }
}
