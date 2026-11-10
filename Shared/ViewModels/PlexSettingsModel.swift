import Combine
import Foundation

/// The Settings › Plex row. It reads the one link the Watchlist store holds, so
/// a link or unlink made anywhere shows here without another load.
@MainActor
final class PlexSettingsModel: ObservableObject {
    enum Row: Equatable {
        case hidden
        case notConnected
        case connected(username: String)
        case needsReconnect(username: String)
    }

    enum Action: Equatable { case connect, reconnect, disconnect }

    @Published private(set) var row: Row

    private let store: WatchlistStore
    private var cancellable: AnyCancellable?

    init(store: WatchlistStore = .shared) {
        self.store = store
        row = Self.row(availability: store.availability, plex: store.watchlist?.plex)
        // @Published fires before the change lands: read the new values from the sink.
        cancellable = Publishers.CombineLatest(store.$availability, store.$watchlist)
            .sink { [weak self] availability, watchlist in
                self?.row = Self.row(availability: availability, plex: watchlist?.plex)
            }
    }

    var status: String {
        switch row {
        case .hidden: return ""
        case .notConnected: return WatchlistText.notConnected
        case .connected(let username), .needsReconnect(let username): return WatchlistText.connectedAs(username)
        }
    }

    var actions: [Action] {
        switch row {
        case .hidden: return []
        case .notConnected: return [.connect]
        case .connected: return [.disconnect]
        case .needsReconnect: return [.reconnect, .disconnect]
        }
    }

    var footer: String { WatchlistText.plexRowFooter }

    /// The row's one line on Apple TV: the status, then what selecting it does.
    var summary: String {
        guard let first = actions.first else { return status }
        return "\(status) · \(first.title)"
    }

    func load() async {
        await store.refresh()
    }

    func disconnect() async -> Bool {
        await store.unlink()
    }

    private static func row(availability: WatchlistStore.Availability, plex: PlexLink?) -> Row {
        guard availability == .available else { return .hidden }
        guard let plex else { return .notConnected }
        return plex.needsReconnect ? .needsReconnect(username: plex.username) : .connected(username: plex.username)
    }
}

extension PlexSettingsModel.Action {
    var title: String {
        switch self {
        case .connect: return WatchlistText.connect
        case .reconnect: return WatchlistText.reconnect
        case .disconnect: return WatchlistText.disconnect
        }
    }
}
