import XCTest
@testable import Sashimi

/// Plex's web sign-in page beside the PIN poll (iPhone, iPad and Mac). The
/// helper is UIKit-free, so it is tested here with fakes for the page and poll.
@MainActor
final class PlexWebSignInTests: XCTestCase {
    /// Plex never sends the browser back, so the poll closes the page.
    func testPlexWebSignInClosesThePageWhenThePollFinishes() async {
        var pageClosed: CheckedContinuation<Void, Never>?
        var closes = 0
        var cancelled = false

        await PlexWebSignIn.run(
            poll: { await Task.yield() },
            showPage: { await withCheckedContinuation { pageClosed = $0 } },
            closePage: { closes += 1; pageClosed?.resume(); pageClosed = nil },
            isWaiting: { false },
            cancelWaiting: { cancelled = true },
            checksStarted: { 0 },
            grace: .zero
        )

        XCTAssertEqual(closes, 1)
        XCTAssertFalse(cancelled, "a finished poll isn't called off")
    }

    /// The person closed the page without signing in: the poll is called off
    /// after its next check and the grace period, instead of waiting 15 minutes.
    func testPlexWebSignInCallsOffThePollWhenThePageIsClosedFirst() async {
        var waiting = true
        var pollCancelled = false
        var checks = 0

        await PlexWebSignIn.run(
            poll: {
                while !Task.isCancelled {
                    checks += 1 // a check that finds no token
                    await Task.yield()
                }
                pollCancelled = true
            },
            showPage: {},
            closePage: {},
            isWaiting: { waiting },
            cancelWaiting: { waiting = false },
            checksStarted: { checks },
            grace: .zero
        )
        for _ in 0..<100 where !pollCancelled { await Task.yield() }

        XCTAssertFalse(waiting)
        XCTAssertTrue(pollCancelled)
    }

    /// The page closed (or the app was suspended past the grace) before the
    /// poll looked again: it still gets that look before being called off, so
    /// a token that landed meanwhile is collected.
    func testClosingThePageStillGetsOneLastCheck() async {
        var waiting = true
        var checks = 0
        var cancelledBeforeCheck = false
        var calledOff = false

        await PlexWebSignIn.run(
            poll: {
                // The poll's next check comes a moment after the page closed, and sees the token.
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled {
                    cancelledBeforeCheck = true
                    return
                }
                checks += 1
                waiting = false
            },
            showPage: {},
            closePage: {},
            isWaiting: { waiting },
            cancelWaiting: { calledOff = true; waiting = false },
            checksStarted: { checks },
            grace: .zero
        )
        for _ in 0..<100 where checks == 0 && !cancelledBeforeCheck {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(cancelledBeforeCheck, "the poll was called off before it looked again")
        XCTAssertFalse(calledOff)
        XCTAssertEqual(checks, 1)
    }

    /// A poll that never looks again (plex.tv hanging) doesn't hold the page
    /// open: the wait for the last check has a cap, then the grace, then it's off.
    func testTheWaitForTheLastCheckIsCapped() async throws {
        var waiting = true
        var calledOff = false
        var finished = false

        let running = Task {
            await PlexWebSignIn.run(
                poll: { while waiting { try? await Task.sleep(for: .milliseconds(20)) } },
                showPage: {},
                closePage: {},
                isWaiting: { waiting },
                cancelWaiting: { calledOff = true },
                checksStarted: { 0 },
                grace: .zero,
                lastCheckCap: .milliseconds(100)
            )
            finished = true
        }
        for _ in 0..<200 where !finished { try await Task.sleep(nanoseconds: 10_000_000) }
        waiting = false // let a run that never ends finish after the test
        running.cancel()

        XCTAssertTrue(finished, "still waiting after 2 s with a 100 ms cap")
        XCTAssertTrue(calledOff)
    }
}

