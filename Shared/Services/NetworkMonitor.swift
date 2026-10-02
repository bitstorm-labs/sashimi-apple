import Foundation
import Network

/// Publishes whether the device currently has a usable network path and, when
/// a target opts in, whether the active Jellyfin server answers. Both platform
/// targets use the same monitor so shared view models can accurately represent
/// offline states without importing a mobile-only service.
///
/// Server probing is opt-in (`startServerProbing`). The iOS app turns it on;
/// tvOS does not, so there `isServerReachable` stays true and `status` /
/// `isOnline` are exactly the network-path answer they always were.
@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    /// The device has a satisfied network path. Says nothing about the server.
    @Published var isConnected = true
    /// Cellular or a personal hotspot (mobile downloads honour this).
    @Published private(set) var isExpensive = false
    /// Low Data Mode.
    @Published private(set) var isConstrained = false
    /// The active server answered its most recent probes (see
    /// `ServerReachabilityTracker` for the hysteresis).
    @Published private(set) var isServerReachable = true

    var status: ConnectionStatus {
        ConnectionStatus.resolve(hasNetworkPath: isConnected, isServerReachable: isServerReachable)
    }

    /// Network path up AND the active server reachable: what anything that
    /// needs the server should check.
    var isOnline: Bool { status == .online }

    /// After a first failure, how soon the confirming probe runs.
    static let confirmationDelay: Duration = .seconds(2)
    /// While unreachable, how often to look again so the app comes back on
    /// its own.
    static let unreachableRecheckInterval: Duration = .seconds(30)
    /// Request failures arrive in bursts (a Home load fans out into a dozen
    /// requests); at most one probe per window.
    static let requestFailureDebounce: TimeInterval = 10

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.mondominator.sashimi.networkMonitor")

    private var tracker = ServerReachabilityTracker()
    private var probe: (@Sendable () async -> Bool)?
    private var probeTask: Task<Void, Never>?
    private var recheckTask: Task<Void, Never>?
    private var lastRequestFailureProbe: Date?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let expensive = path.isExpensive
            let constrained = path.isConstrained
            Task { @MainActor [weak self] in
                self?.pathDidChange(satisfied: satisfied, expensive: expensive, constrained: constrained)
            }
        }
        monitor.start(queue: monitorQueue)
    }

    // MARK: - Server probing

    /// Turns on server reachability for this process. `probe` answers whether
    /// the active server responded; it is called on launch, on every network
    /// path change, on `requestProbe()`, after request failures, and
    /// periodically while the server is unreachable. Calling it again (a
    /// server switch) starts the verdict over: it was about the old server.
    func startServerProbing(probe: @escaping @Sendable () async -> Bool) {
        self.probe = probe
        resetServerReachability()
    }

    /// The active server changed: the old verdict was about another server.
    func resetServerReachability() {
        probeTask?.cancel()
        probeTask = nil
        recheckTask?.cancel()
        recheckTask = nil
        tracker.reset()
        isServerReachable = true
        requestProbe()
    }

    /// Probe now unless one is already in flight. No-op until probing starts
    /// and while there is no network path (that state needs no probe).
    func requestProbe() {
        guard let probe, isConnected, probeTask == nil else { return }
        probeTask = Task { [weak self] in
            let reachable = await probe()
            guard !Task.isCancelled else { return }
            self?.probeFinished(reachable: reachable)
        }
    }

    /// An API request to `serverURL` failed at the transport level (timeout,
    /// connection refused, host not found) or with a gateway error. Probes,
    /// debounced, when that server is the active one.
    func noteServerRequestFailure(serverURL: URL?) {
        guard probe != nil,
              let serverURL,
              serverURL == SessionManager.shared.serverURL else { return }
        let now = Date()
        if let last = lastRequestFailureProbe,
           now.timeIntervalSince(last) < Self.requestFailureDebounce {
            return
        }
        lastRequestFailureProbe = now
        requestProbe()
    }

    private func pathDidChange(satisfied: Bool, expensive: Bool, constrained: Bool) {
        // Only what changed, expense first: a subscriber woken by
        // isConnected then already sees the new path's cost.
        if isExpensive != expensive { isExpensive = expensive }
        if isConstrained != constrained { isConstrained = constrained }
        isConnected = satisfied
        // Any path change (regained, Wi-Fi to cellular) can change whether
        // the server is reachable. Losing the path drops the in-flight probe
        // instead: it would fail for the wrong reason and count against the
        // server once the path is back.
        if satisfied {
            requestProbe()
        } else {
            probeTask?.cancel()
            probeTask = nil
            recheckTask?.cancel()
            recheckTask = nil
        }
    }

    private func probeFinished(reachable: Bool) {
        probeTask = nil
        guard isConnected else { return }
        if tracker.record(probeSucceeded: reachable) {
            isServerReachable = tracker.isReachable
        }
        scheduleRecheck()
    }

    private func scheduleRecheck() {
        recheckTask?.cancel()
        recheckTask = nil
        let delay: Duration
        if tracker.needsConfirmation {
            delay = Self.confirmationDelay
        } else if !tracker.isReachable {
            delay = Self.unreachableRecheckInterval
        } else {
            return
        }
        recheckTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.requestProbe()
        }
    }
}
