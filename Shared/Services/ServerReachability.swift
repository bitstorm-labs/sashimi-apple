import Foundation

/// What the app can reach right now. `noNetwork` is the device having no
/// usable network path at all; `serverUnreachable` is a working network that
/// cannot get to the active Jellyfin server (server down, VPN off, a captive
/// portal, a reverse proxy answering 502). Both are "offline" for anything
/// that needs the server, but they read differently to the viewer.
enum ConnectionStatus: Equatable {
    case online
    case noNetwork
    case serverUnreachable

    static func resolve(hasNetworkPath: Bool, isServerReachable: Bool) -> ConnectionStatus {
        guard hasNetworkPath else { return .noNetwork }
        return isServerReachable ? .online : .serverUnreachable
    }
}

/// Turns a stream of server-probe results into a reachable / unreachable
/// verdict with hysteresis, so one dropped request on a flaky link does not
/// flip the whole app into offline mode and back.
///
/// Going offline takes `failuresToGoOffline` consecutive failed probes; coming
/// back takes a single success (a server that answered is reachable).
struct ServerReachabilityTracker: Equatable {
    static let failuresToGoOffline = 2
    /// Upper bound on one probe, so a black-holed server is detected in
    /// seconds rather than after the API session's 30 s request timeout.
    static let probeTimeout: TimeInterval = 4

    private(set) var isReachable = true
    private(set) var consecutiveFailures = 0

    /// Records one probe result. Returns true when `isReachable` changed.
    @discardableResult
    mutating func record(probeSucceeded: Bool) -> Bool {
        if probeSucceeded {
            consecutiveFailures = 0
            guard !isReachable else { return false }
            isReachable = true
            return true
        }
        consecutiveFailures += 1
        guard isReachable, consecutiveFailures >= Self.failuresToGoOffline else { return false }
        isReachable = false
        return true
    }

    /// A failure has been seen but not yet confirmed: probe again soon rather
    /// than waiting for the slow unreachable re-check interval.
    var needsConfirmation: Bool {
        isReachable && consecutiveFailures > 0
    }

    mutating func reset() {
        self = ServerReachabilityTracker()
    }
}
