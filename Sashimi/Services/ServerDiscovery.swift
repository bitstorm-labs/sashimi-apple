import Foundation
import Network

/// Discovers Jellyfin servers on the local network using mDNS/Bonjour
@MainActor
final class ServerDiscovery: ObservableObject {
    @Published private(set) var discoveredServers: [DiscoveredServer] = []
    @Published private(set) var isSearching = false

    private var browser: NWBrowser?

    struct DiscoveredServer: Identifiable, Hashable {
        let id = UUID()
        let name: String
        let address: String
        let port: Int

        var url: URL? {
            URL(string: "http://\(address):\(port)")
        }
    }

    func startDiscovery() {
        guard !isSearching else { return }

        isSearching = true
        discoveredServers = []

        // Browse for Jellyfin servers (they advertise as _jellyfin._tcp)
        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        browser = NWBrowser(for: .bonjour(type: "_jellyfin._tcp", domain: nil), using: parameters)

        browser?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    break
                case .failed, .cancelled:
                    self?.isSearching = false
                default:
                    break
                }
            }
        }

        browser?.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.processResults(results)
            }
        }

        browser?.start(queue: .main)

        // Stop after 10 seconds
        Task {
            try? await Task.sleep(for: .seconds(10))
            stopDiscovery()
        }
    }

    func stopDiscovery() {
        browser?.cancel()
        browser = nil
        isSearching = false
    }

    private func processResults(_ results: Set<NWBrowser.Result>) {
        for result in results {
            if case let .service(name, _, _, _) = result.endpoint {
                // Resolve the service to get the actual address
                resolveService(result: result, name: name)
            }
        }
    }

    private func resolveService(result: NWBrowser.Result, name: String) {
        let connection = NWConnection(to: result.endpoint, using: .tcp)

        connection.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                if let endpoint = connection.currentPath?.remoteEndpoint,
                   case let .hostPort(host, port) = endpoint {
                    let address: String
                    switch host {
                    case .ipv4(let ipv4):
                        address = "\(ipv4)"
                    case .ipv6(let ipv6):
                        address = "\(ipv6)"
                    case .name(let hostname, _):
                        address = hostname
                    @unknown default:
                        address = "unknown"
                    }

                    Task { @MainActor in
                        let server = DiscoveredServer(
                            name: name,
                            address: address,
                            port: Int(port.rawValue)
                        )
                        if let strongSelf = self,
                           !strongSelf.discoveredServers.contains(where: { $0.address == address && $0.port == server.port }) {
                            strongSelf.discoveredServers.append(server)
                        }
                    }
                }
                connection.cancel()
            }
        }

        connection.start(queue: .main)
    }

    deinit {
        browser?.cancel()
    }
}
