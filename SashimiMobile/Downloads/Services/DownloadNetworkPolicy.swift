import Combine
import Foundation

/// The network facts the download rules depend on, read from NWPath.
struct DownloadNetworkStatus: Equatable {
    var isConnected: Bool
    /// Cellular or a personal hotspot.
    var isExpensive: Bool
    /// Low Data Mode.
    var isConstrained: Bool

    @MainActor
    static var current: DownloadNetworkStatus {
        let monitor = NetworkMonitor.shared
        return DownloadNetworkStatus(
            isConnected: monitor.isConnected,
            isExpensive: monitor.isExpensive,
            isConstrained: monitor.isConstrained
        )
    }
}

/// Why downloads can't move right now.
enum DownloadWaitReason: Equatable {
    case offline
    /// On cellular or a hotspot with "Download over Cellular" off.
    case cellular
    /// On a Low Data Mode network with "Download over Cellular" off.
    case lowDataMode

    var activeLabel: String {
        switch self {
        case .offline: return "Waiting for network"
        case .cellular: return "Waiting for Wi-Fi"
        case .lowDataMode: return "Waiting (Low Data Mode)"
        }
    }
}

/// "Download over Cellular": off (the default) keeps every download, manual
/// or automatic, to Wi-Fi. Enforced per request, so the background session
/// itself never has to be recreated.
enum DownloadNetworkPolicy {
    static let allowCellularKey = "downloadOverCellular"

    static var allowsCellular: Bool {
        UserDefaults.standard.bool(forKey: allowCellularKey)
    }

    static func waitReason(allowCellular: Bool, network: DownloadNetworkStatus) -> DownloadWaitReason? {
        guard network.isConnected else { return .offline }
        guard !allowCellular else { return nil }
        if network.isExpensive { return .cellular }
        if network.isConstrained { return .lowDataMode }
        return nil
    }

    /// Whether a download started now would move data straight away. Keep-next
    /// and automatic retries only act when this is true.
    static func canDownloadNow(allowCellular: Bool, network: DownloadNetworkStatus) -> Bool {
        waitReason(allowCellular: allowCellular, network: network) == nil
    }

    /// Wi-Fi-only also rules out hotspots (expensive) and Low Data Mode
    /// (constrained). A background task that may not use the current network
    /// waits for one it may use rather than failing.
    static func apply(to request: inout URLRequest, allowCellular: Bool) {
        request.allowsCellularAccess = allowCellular
        request.allowsExpensiveNetworkAccess = allowCellular
        request.allowsConstrainedNetworkAccess = allowCellular
    }

    /// A task keeps the network access it was created with. When that no
    /// longer matches the setting and it matters on the current network
    /// (cellular, hotspot or Low Data Mode), the task must be recreated:
    /// either it is waiting for Wi-Fi the user no longer requires, or it is
    /// using cellular the user just turned off. On plain Wi-Fi both kinds of
    /// task behave the same, so nothing is restarted and no progress is lost.
    static func shouldRestartTask(
        taskAllowsCellular: Bool,
        allowCellular: Bool,
        network: DownloadNetworkStatus
    ) -> Bool {
        guard taskAllowsCellular != allowCellular, network.isConnected else { return false }
        return network.isExpensive || network.isConstrained
    }
}

extension NetworkMonitor {
    /// The path as the download rules see it, emitted on the main queue once
    /// it settles. @Published emits before the property is stored, so the
    /// debounce also guarantees `DownloadNetworkStatus.current` is up to date
    /// by the time a subscriber runs.
    var downloadStatusPublisher: AnyPublisher<DownloadNetworkStatus, Never> {
        Publishers.CombineLatest3($isConnected, $isExpensive, $isConstrained)
            .map { DownloadNetworkStatus(isConnected: $0, isExpensive: $1, isConstrained: $2) }
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
}
