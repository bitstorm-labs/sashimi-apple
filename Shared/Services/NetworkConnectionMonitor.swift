import Foundation
import Network

/// Observes the active network interface so playback can tell a wired link
/// from a wireless one.
///
/// This is the axis that actually matters for copy-vs-transcode, and the one
/// the old local-vs-remote (by IP) split got wrong: a 66 Mbps 4K source that
/// copies fine over Ethernet stalls over Wi-Fi, whatever the bandwidth probe
/// measured. An 8 MB burst probe reads Wi-Fi's *peak*, not the sustained rate,
/// and even a correct average can't cover a VBR source's peaks on Wi-Fi — so
/// the reliable rule is "don't copy heavy 4K over a wireless link", and that
/// needs to know the link is wireless.
///
/// Defaults to *not wired* until the first path update lands (which happens
/// within milliseconds of `start()`), so the conservative wireless ceiling
/// applies during the brief startup window rather than optimistically allowing
/// a copy.
final class NetworkConnectionMonitor: @unchecked Sendable {
    static let shared = NetworkConnectionMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.mondominator.sashimi.network-monitor")
    private let lock = NSLock()
    private var wired = false
    private var metered = false
    private var started = false
    /// Distinguishes the initial path update from a real interface change.
    private var hasReceivedPath = false

    /// Whether the current path runs over wired Ethernet. False for Wi-Fi,
    /// cellular, or before the first path update.
    var isWired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return wired
    }

    /// Whether the current path costs the viewer data: cellular or a personal
    /// hotspot (`isExpensive`), or Low Data Mode (`isConstrained`). The
    /// bandwidth probe never runs on such a path. False before the first
    /// path update — callers that must not guess wait for it
    /// (`waitForFirstPath`).
    var isMetered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return metered
    }

    var hasPath: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasReceivedPath
    }

    /// Waits (bounded) for the first path update, so a decision taken right
    /// after `start()` sees the real interface instead of the defaults. The
    /// update normally lands within milliseconds; the bound only matters if
    /// it never does.
    func waitForFirstPath(timeout: Duration = .seconds(1)) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !hasPath, ContinuousClock.now < deadline {
            guard (try? await Task.sleep(for: .milliseconds(20))) != nil else { return }
        }
    }

    /// Whether a path change should re-run the bandwidth probe: the old
    /// measurement was taken on another kind of link, or the new link's cost
    /// changes whether the probe may run at all. The initial path update is
    /// covered by the login-time probe.
    static func invalidatesMeasurement(
        hadPath: Bool,
        wasWired: Bool, isWired: Bool,
        wasMetered: Bool, isMetered: Bool
    ) -> Bool {
        hadPath && (wasWired != isWired || wasMetered != isMetered)
    }

    private init() {}

    /// Begins monitoring. Idempotent — safe to call on every login.
    func start() {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        monitor.pathUpdateHandler = { [weak self] path in
            let isWired = path.status == .satisfied && path.usesInterfaceType(.wiredEthernet)
            let isMetered = path.isExpensive || path.isConstrained
            guard let self else { return }
            self.lock.lock()
            let changed = Self.invalidatesMeasurement(
                hadPath: self.hasReceivedPath,
                wasWired: self.wired, isWired: isWired,
                wasMetered: self.metered, isMetered: isMetered
            )
            self.hasReceivedPath = true
            self.wired = isWired
            self.metered = isMetered
            self.lock.unlock()
            // A wired<->wireless or Wi-Fi<->cellular transition invalidates
            // the bandwidth measurement (it was taken on the other link), so
            // re-probe — or, onto a metered link, drop it for the default.
            if changed {
                Task { await JellyfinClient.shared.startBandwidthMeasurement() }
            }
        }
        monitor.start(queue: queue)
    }
}
