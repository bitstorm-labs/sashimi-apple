import AuthenticationServices
import UIKit

/// Plex's sign-in page beside the PIN poll. Plex's page can't send the
/// browser back to `sashimi://` (it only forwards to Plex's own apps), so the
/// poll is what finishes sign-in, and it closes the page when it ends.
@MainActor
enum PlexWebSignIn {
    /// - `poll`: waits for the PIN to be linked (or to expire).
    /// - `showPage`: returns when the page is closed, by the person or by `closePage`.
    /// - `isWaiting` / `cancelWaiting`: once the person closes the page, the
    ///   poll gets `grace` to see a token that just landed, then is called off.
    static func run(
        poll: @escaping @MainActor () async -> Void,
        showPage: @MainActor () async -> Void,
        closePage: @escaping @MainActor () -> Void,
        isWaiting: @MainActor () -> Bool,
        cancelWaiting: @MainActor () -> Void,
        grace: Duration = .seconds(5)
    ) async {
        let pollTask = Task { @MainActor in
            await poll()
            closePage()
        }
        await showPage()
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

/// Plex's sign-in page in the system's web-authentication sheet, which the
/// app can close once the PIN is linked (SwiftUI's `webAuthenticationSession`
/// only closes on a callback URL, and Plex never sends one).
@MainActor
final class PlexSignInPage: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var finished: CheckedContinuation<Void, Never>?

    /// Returns when the person closes the page or `close()` is called.
    func show(_ url: URL) async {
        await withCheckedContinuation { continuation in
            finished = continuation
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { [weak self] _, _ in
                Task { @MainActor in self?.finish() }
            }
            session.presentationContextProvider = self
            self.session = session
            if !session.start() { finish() }
        }
    }

    func close() {
        session?.cancel()
        finish()
    }

    private func finish() {
        session = nil
        finished?.resume()
        finished = nil
    }

    // AuthenticationServices asks for the anchor on the main thread when it
    // presents the sheet, which `start()` (main actor) triggers.
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let windows = scenes.flatMap(\.windows)
            return windows.first(where: \.isKeyWindow) ?? windows.first ?? ASPresentationAnchor()
        }
    }
}
