import AuthenticationServices
import UIKit

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
