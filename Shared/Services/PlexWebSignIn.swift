import Foundation

/// Plex's sign-in page beside the PIN poll. Plex's page can't send the
/// browser back to `sashimi://` (it only forwards to Plex's own apps), so the
/// poll is what finishes sign-in, and it closes the page when it ends.
@MainActor
enum PlexWebSignIn {
    /// - `poll`: waits for the PIN to be linked (or to expire).
    /// - `showPage`: returns when the page is closed, by the person or by `closePage`.
    /// - `isWaiting` / `cancelWaiting`: once the person closes the page, the
    ///   poll finishes one check that started after the page closed (a token
    ///   that landed meanwhile is seen even if the app was suspended past the
    ///   grace), then gets `grace` more, then is called off.
    /// - `checksStarted`: how many PIN checks the poll has started so far.
    ///
    /// Six hooks, each supplied separately by the page and the poll's owner.
    static func run( // swiftlint:disable:this function_parameter_count
        poll: @escaping @MainActor () async -> Void,
        showPage: @MainActor () async -> Void,
        closePage: @escaping @MainActor () -> Void,
        isWaiting: @MainActor () -> Bool,
        cancelWaiting: @MainActor () -> Void,
        checksStarted: @MainActor () -> Int,
        grace: Duration = .seconds(5)
    ) async {
        let pollTask = Task { @MainActor in
            await poll()
            closePage()
        }
        await showPage()
        // Checks run one after another: once the second check after the page
        // closed has started, the first one finished without a token. A check
        // that finds the token ends the wait instead (`isWaiting` turns false).
        let closedAt = checksStarted()
        while isWaiting(), !Task.isCancelled, checksStarted() < closedAt + 2 {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let deadline = ContinuousClock.now + grace
        while isWaiting(), !Task.isCancelled, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }
        if isWaiting() {
            pollTask.cancel()
            cancelWaiting()
        }
    }
}
