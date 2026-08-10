import Foundation
import Network

/// Publishes whether the device currently has a usable network path. Both
/// platform targets use the same monitor so shared view models can accurately
/// represent offline states without importing a mobile-only service.
@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    @Published var isConnected = true

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.mondominator.sashimi.networkMonitor")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.isConnected = path.status == .satisfied
            }
        }
        monitor.start(queue: monitorQueue)
    }
}
