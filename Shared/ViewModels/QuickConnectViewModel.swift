import Foundation

/// Drives a Quick Connect sign-in: ask the server for a code, show it, poll
/// until another signed-in device approves it, then sign in through the same
/// path as a password sign-in.
///
/// The poll is one `Task`; cancelling it (Cancel, Back, leaving the screen)
/// is the only way it stops early, and no request is made after that.
@MainActor
final class QuickConnectViewModel: ObservableObject {
    enum Phase: Equatable {
        /// Not running: the login form is showing.
        case idle
        /// Asking the server for a code.
        case requesting
        /// Showing the code and polling for approval.
        case waiting(code: String)
        /// Approved; trading the secret for a session.
        case signingIn
        case signedIn
        /// The server dropped the request (10 minutes) before it was approved.
        case expired
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// Whether to offer Quick Connect at all: true only when the server says
    /// it's enabled.
    @Published private(set) var isAvailable = false

    /// Called once the session is saved, for presenters that need to dismiss.
    var onSignedIn: (() -> Void)?

    private let service: QuickConnectService
    private let pollInterval: Duration
    /// Polls that may fail in a row (a Wi-Fi blip, a server restart) before
    /// giving up. Expiry is not a failure: it ends the request immediately.
    private let maxConsecutiveFailures: Int
    private var pollTask: Task<Void, Never>?
    private var serverURL: URL?

    init(
        service: QuickConnectService = LiveQuickConnectService.shared,
        pollInterval: Duration = .seconds(3),
        maxConsecutiveFailures: Int = 5
    ) {
        self.service = service
        self.pollInterval = pollInterval
        self.maxConsecutiveFailures = maxConsecutiveFailures
    }

    /// True while the code screen should replace the login form.
    var isActive: Bool { phase != .idle }

    /// "482917" → "4 8 2 9 1 7", so the code reads at a distance.
    static func spaced(_ code: String) -> String {
        code.map(String.init).joined(separator: " ")
    }

    /// Asks `serverURL` whether it accepts Quick Connect. Nil (no valid
    /// address yet) hides the button.
    func refreshAvailability(for serverURL: URL?) async {
        guard let serverURL else {
            isAvailable = false
            return
        }
        let enabled = await service.isEnabled(serverURL: serverURL)
        guard !Task.isCancelled else { return }
        isAvailable = enabled
    }

    /// Starts a new request, replacing any running one.
    func start(serverURL: URL) {
        pollTask?.cancel()
        self.serverURL = serverURL
        phase = .requesting
        pollTask = Task { [weak self] in
            await self?.run(serverURL: serverURL)
        }
    }

    /// Get New Code / Try Again: a fresh request against the same server.
    func requestNewCode() {
        guard let serverURL else { return }
        start(serverURL: serverURL)
    }

    /// Stops polling and returns to the login form.
    func cancel() {
        pollTask?.cancel()
        pollTask = nil
        phase = .idle
    }

    private func run(serverURL: URL) async {
        let secret: String
        do {
            let request = try await service.initiate(serverURL: serverURL)
            guard !Task.isCancelled else { return }
            secret = request.secret
            phase = .waiting(code: request.code)
        } catch {
            fail(with: error)
            return
        }

        var failures = 0
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                return  // cancelled while waiting
            }
            do {
                let state = try await service.state(serverURL: serverURL, secret: secret)
                guard !Task.isCancelled else { return }
                failures = 0
                guard state.authenticated else { continue }

                phase = .signingIn
                try await service.signIn(serverURL: serverURL, secret: secret)
                guard !Task.isCancelled else { return }
                phase = .signedIn
                onSignedIn?()
                return
            } catch QuickConnectError.expired {
                guard !Task.isCancelled else { return }
                phase = .expired
                return
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                failures += 1
                // A failed sign-in after approval is reported, not retried:
                // the server expires an approved request a minute later.
                if phase == .signingIn || failures >= maxConsecutiveFailures {
                    fail(with: error)
                    return
                }
            }
        }
    }

    private func fail(with error: Error) {
        guard !Task.isCancelled, !(error is CancellationError) else { return }
        switch error {
        case QuickConnectError.disabled:
            phase = .failed("Quick Connect is turned off on this server.")
        case JellyfinError.invalidCredentials:
            // Not "wrong username or password": no password was involved.
            phase = .failed("The server refused the Quick Connect sign-in. Get a new code and try again.")
        default:
            phase = .failed(SignInFailure.message(for: error) ?? error.localizedDescription)
        }
    }
}
