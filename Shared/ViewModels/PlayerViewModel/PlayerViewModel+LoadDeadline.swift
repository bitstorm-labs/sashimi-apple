import Foundation

/// How long a playback load may sit without making progress (#594).
///
/// The two platforms disagreed, and both were wrong. iOS raised "Can't connect
/// to server" five seconds after the load started, whatever the load was doing
/// — over a remote link with a cold server the load was simply still running,
/// and the player then appeared underneath the error. tvOS had no bound at
/// all, so a dead server left a bare spinner for as long as the requests took
/// to give up (about two minutes).
///
/// One rule for both: the clock measures time since the last sign of progress
/// (a response arriving), not time since the start. A slow load that keeps
/// answering is never interrupted; one that has gone quiet is cancelled and
/// reported.
enum PlaybackLoadPolicy {
    /// Longest silence tolerated. Comfortably above a cold PlaybackInfo (the
    /// server probing a file it has not opened before) over a remote link,
    /// and well under the request layer's own 30 s timeout plus retries.
    static let stallBudget: TimeInterval = 20

    enum Verdict: Equatable {
        case keepWaiting
        case giveUp
    }

    static func verdict(secondsSinceProgress: TimeInterval, budget: TimeInterval = stallBudget) -> Verdict {
        secondsSinceProgress >= budget ? .giveUp : .keepWaiting
    }
}

@MainActor
private final class LoadDeadlineState {
    var expired = false
}

extension PlayerViewModel {
    /// Marks a step of the load as done. Each request that comes back resets
    /// the deadline.
    func noteLoadProgress() {
        lastLoadProgress = Date()
    }

    /// Runs the network part of a load under the no-progress deadline.
    ///
    /// On expiry the work is cancelled (URLSession and the retry back-off both
    /// honour task cancellation, so nothing keeps running behind the error)
    /// and `PlayerError.loadTimedOut` is thrown in place of the cancellation.
    func withLoadDeadline(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        noteLoadProgress()
        let work = Task { @MainActor in try await operation() }
        let deadline = LoadDeadlineState()
        let monitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                let quiet = Date().timeIntervalSince(self.lastLoadProgress)
                if PlaybackLoadPolicy.verdict(secondsSinceProgress: quiet, budget: self.loadStallBudget) == .giveUp {
                    deadline.expired = true
                    work.cancel()
                    return
                }
            }
        }
        defer { monitor.cancel() }
        do {
            try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
        } catch {
            guard deadline.expired else { throw error }
            diagFailure(.loadFailed, [PlayerDiagnostics.field("outcome", "no-progress-timeout")])
            throw PlayerError.loadTimedOut(serverReachable: NetworkMonitor.shared.isOnline)
        }
    }
}
