import Foundation
import Network
import os

private let logger = Logger(subsystem: "com.mondominator.sashimi", category: "ServerDiscovery")

/// Discovers Jellyfin servers on the local network.
///
/// Uses Jellyfin's own auto-discovery protocol: broadcast the literal string
/// `Who is JellyfinServer?` to UDP 7359 and collect the JSON replies.
///
/// This previously browsed Bonjour for `_jellyfin._tcp`, which finds nothing --
/// Jellyfin does not advertise that service. Verified with `dns-sd -B` against a
/// live 10.11 server on host networking: zero results, while the UDP broadcast
/// replied immediately. The Roku client has always used this protocol.
///
/// `NSBonjourServices` / `NSLocalNetworkUsageDescription` are still required in
/// Info.plist: the local-network privacy gate covers UDP broadcast too.
@MainActor
final class ServerDiscovery: ObservableObject {
    @Published private(set) var discoveredServers: [DiscoveredServer] = []
    @Published private(set) var isSearching = false

    private var listenTask: Task<Void, Never>?

    private static let discoveryPort: UInt16 = 7359
    private static let probe = "Who is JellyfinServer?"
    /// Long enough for a busy server to answer, short enough that the UI does
    /// not feel hung when nothing is there.
    private static let listenSeconds: TimeInterval = 3

    struct DiscoveredServer: Identifiable, Hashable {
        /// Jellyfin's own server id, so repeated probes dedupe to one entry
        /// rather than stacking.
        let id: String
        let name: String
        let address: String
        let port: Int

        // Discovered servers are addressed over plain HTTP on purpose:
        // discovery only reaches the local network, where Jellyfin's default
        // setup is HTTP, and a self-signed HTTPS guess would fail validation
        // anyway. Users can still type an https:// URL manually.
        var url: URL? {
            URL(string: "http://\(address):\(port)")
        }
    }

    /// The subset of Jellyfin's discovery reply we act on.
    private struct DiscoveryReply: Decodable {
        let id: String
        let name: String
        let address: String?

        enum CodingKeys: String, CodingKey {
            case id = "Id"
            case name = "Name"
            case address = "Address"
        }
    }

    func startDiscovery() {
        guard !isSearching else { return }
        isSearching = true
        discoveredServers = []

        listenTask = Task { [weak self] in
            let replies = await Self.probeNetwork()
            guard let self, !Task.isCancelled else { return }
            for reply in replies where !self.discoveredServers.contains(where: { $0.id == reply.id }) {
                self.discoveredServers.append(reply)
            }
            self.isSearching = false
        }
    }

    func stopDiscovery() {
        listenTask?.cancel()
        listenTask = nil
        isSearching = false
    }

    /// Broadcasts the probe and gathers replies.
    ///
    /// Runs off the main actor on a blocking BSD socket: Network.framework has
    /// no first-class broadcast send, and a datagram listener would still need
    /// the same receive loop.
    nonisolated private static func probeNetwork() async -> [DiscoveredServer] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: blockingProbe())
            }
        }
    }

    nonisolated private static func blockingProbe() -> [DiscoveredServer] {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else {
            logger.error("discovery: socket() failed")
            return []
        }
        defer { close(sock) }

        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))

        // Bounded receive so the loop cannot outlive the window if replies stop.
        var timeout = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var destination = sockaddr_in()
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = discoveryPort.bigEndian
        destination.sin_addr.s_addr = INADDR_BROADCAST

        let payload = Array(probe.utf8)
        let sent = withUnsafePointer(to: &destination) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addr in
                sendto(sock, payload, payload.count, 0, addr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard sent > 0 else {
            logger.error("discovery: broadcast send failed")
            return []
        }

        var found: [DiscoveredServer] = []
        var buffer = [UInt8](repeating: 0, count: 2048)
        let deadline = Date().addingTimeInterval(listenSeconds)

        while Date() < deadline {
            var from = sockaddr_in()
            var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let received = withUnsafeMutablePointer(to: &from) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addr in
                    recvfrom(sock, &buffer, buffer.count, 0, addr, &fromLength)
                }
            }
            guard received > 0 else { continue }   // timeout tick; keep waiting

            guard let reply = try? JSONDecoder().decode(
                DiscoveryReply.self,
                from: Data(buffer[0..<received])
            ) else { continue }

            // Prefer the responder's source IP over the reply's `Address`: that
            // field carries whatever the admin set as the public URL (often an
            // external hostname), which is not what we want for a server we
            // just found on the LAN.
            let sourceIP = String(cString: inet_ntoa(from.sin_addr))
            let port = Self.port(fromAdvertised: reply.address) ?? 8096

            if !found.contains(where: { $0.id == reply.id }) {
                found.append(DiscoveredServer(id: reply.id, name: reply.name, address: sourceIP, port: port))
            }
        }
        return found
    }

    /// Pulls the port out of the advertised address, since the reply carries no
    /// separate port field and the server may not be on the default 8096.
    nonisolated static func port(fromAdvertised address: String?) -> Int? {
        guard let address,
              let components = URLComponents(string: address.contains("://") ? address : "http://\(address)")
        else { return nil }
        return components.port
    }

    deinit {
        listenTask?.cancel()
    }
}
